import AppKit
import ApplicationServices

/// Tracks what kind of element has keyboard focus in the frontmost app.
///
/// Two rules govern everything here.
///
/// **Never from the key thread.** `AXUIElementCopyAttributeValue` is a synchronous
/// XPC call into another app's main thread. A wedged Chrome would wedge our tap
/// callback, and the callback budget is one second (00-DECISIONS.md, Н7) after
/// which macOS disables the tap. So we listen for focus notifications, cache the
/// answer, and let the key thread read the cache.
///
/// **Silence when unsure.** Chromium and Electron build their accessibility tree
/// lazily, so the first query after launch often returns a coarse `AXWebArea`
/// instead of the actual field. We report `.unknown` for that, and `.unknown`
/// is refused by `VetoGate` — guessing would eventually guess a password field.
final class FocusMonitor {

    private(set) var fieldRole: FieldRole = .unknown

    /// Raw strings the last query returned, for diagnostics. These are interface
    /// structure names ("AXTextField"), never anything the user typed.
    private(set) var lastRole: String = "—"
    private(set) var lastSubrole: String = "—"
    private(set) var lastError: String = "—"
    /// How often a retry turned an `unknown` into a real answer.
    private(set) var wakeSuccesses = 0
    private(set) var wakeAttempts = 0

    /// A short history of what each app reported. Focus moves faster than any
    /// single snapshot can be read, so the compatibility table in
    /// `08-TESTING.md` is built from this rather than from a live glance.
    /// Interface structure names only — never anything typed. M3 scaffolding.
    struct Observation { let app: String; let role: String; let subrole: String; let verdict: FieldRole }
    private(set) var history: [Observation] = []

    /// Called on the main thread whenever the focused element changes.
    var onFocusChanged: ((FieldRole) -> Void)?

    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var observedPID: pid_t = 0

    /// Apps whose text fields we classify by app rather than by AX role.
    var terminalBundleIDs: Set<String> = AppPolicyStore.lockedExclusions
    var editorBundleIDs: Set<String> = AppPolicyStore.defaultDisabled

    // MARK: - Lifecycle

    func observe(pid: pid_t, bundleID: String) {
        guard pid != observedPID else { return }
        stop()
        observedPID = pid

        let app = AXUIElementCreateApplication(pid)
        // 200 ms and then we give up. Without this a hung app hangs us.
        AXUIElementSetMessagingTimeout(app, 0.2)
        observedElement = app

        var created: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // Hop off the notification callback before doing AX work.
            DispatchQueue.main.async { monitor.refresh() }
        }, &created)

        guard result == .success, let created else {
            // Most likely .apiDisabled (-25211): our own access is not what the
            // checkbox in System Settings claims. Say nothing, do nothing.
            fieldRole = .unknown
            return
        }

        tryEnableManualAccessibility(on: app)

        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedUIElementChangedNotification,
                             kAXFocusedWindowChangedNotification] as [CFString] {
            AXObserverAddNotification(created, app, notification, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(created),
                           .commonModes)

        refresh(bundleID: bundleID)
    }

    /// Electron exposes `AXManualAccessibility` to turn its tree on. Chromium
    /// proper does not, and answers `-25205 attributeUnsupported`, which is
    /// normal rather than an error.
    ///
    /// Note what is deliberately absent: `AXEnhancedUserInterface`. It does wake
    /// Chromium, but it is private, and setting it makes windows resize and jump
    /// around under the user. Breaking someone's window layout to detect a text
    /// field is not a trade this project makes.
    private(set) var manualAccessibilityResult = "—"

    private func tryEnableManualAccessibility(on app: AXUIElement) {
        let status = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString,
                                                  kCFBooleanTrue)
        manualAccessibilityResult = Self.describe(status)
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                  AXObserverGetRunLoopSource(observer),
                                  .commonModes)
        }
        observer = nil
        observedElement = nil
        observedPID = 0
        isWaking = false
        fieldRole = .unknown
    }

    // MARK: - Reading the focused element

    func refresh(bundleID: String? = nil) {
        let id = bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        // App-level classification first: it is certain, and it is cheap.
        if terminalBundleIDs.contains(id) { publish(.terminal); return }
        if editorBundleIDs.contains(id) { publish(.code); return }

        guard let app = observedElement else { publish(.unknown); return }

        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let element = focused else {
            lastError = Self.describe(status)
            lastRole = "—"; lastSubrole = "—"
            publish(.unknown)
            scheduleWakeRetry(bundleID: id)
            return
        }
        lastError = "—"

        let target = element as! AXUIElement
        AXUIElementSetMessagingTimeout(target, 0.2)

        // One round trip for both attributes instead of two.
        var values: CFArray?
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute] as CFArray
        let multi = AXUIElementCopyMultipleAttributeValues(target, attributes, .init(), &values)

        var role: String?
        var subrole: String?
        if multi == .success, let array = values as? [Any] {
            role = array.count > 0 ? array[0] as? String : nil
            subrole = array.count > 1 ? array[1] as? String : nil
        } else {
            var single: CFTypeRef?
            if AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &single) == .success {
                role = single as? String
            }
            if AXUIElementCopyAttributeValue(target, kAXSubroleAttribute as CFString, &single) == .success {
                subrole = single as? String
            }
        }

        lastRole = role ?? "—"
        lastSubrole = subrole ?? "—"

        let classified = Self.classify(role: role, subrole: subrole)
        publish(classified)
        if classified == .unknown { scheduleWakeRetry(bundleID: id) }
    }

    // MARK: - Waking Chromium up

    /// Chromium and Electron build their accessibility tree on demand, so the
    /// first query after focus lands often returns a bare `AXWebArea` where the
    /// text field should be. Asking again is the documented remedy — the act of
    /// querying is what triggers the build — but it is neither instant nor
    /// guaranteed, so this retries on a short ladder and then gives up.
    ///
    /// Giving up means staying at `.unknown`, which `VetoGate` refuses. In a
    /// browser we would rather do nothing than guess, because the thing we would
    /// be guessing about is whether this is a password field.
    /// One ladder at a time, and never more rungs than this.
    ///
    /// The first version cleared its own guard immediately before re-querying,
    /// and since the re-query also ends in `unknown` it started a fresh ladder
    /// every time — 13 938 attempts in a few minutes, each one an XPC round trip
    /// into another app. Exactly the "eats CPU and heats the laptop" failure the
    /// project treats as disqualifying. Hence a flag that spans the whole ladder
    /// and is cleared in one place.
    private var isWaking = false
    private static let wakeDelays: [TimeInterval] = [0.15, 0.4, 1.0]

    private func scheduleWakeRetry(bundleID: String) {
        guard !isWaking else { return }
        isWaking = true
        retryWake(bundleID: bundleID, step: 0)
    }

    /// Asking for the window list is a heavier request than asking for focus,
    /// and in some Chromium builds that is enough to make the tree get built.
    /// Cheap to try, harmless if it does nothing.
    private func nudgeTree() {
        guard let app = observedElement else { return }
        var windows: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        nudgeResult = "\(Self.describe(status)), окон: \((windows as? [AnyObject])?.count ?? 0)"
    }

    private(set) var nudgeResult = "—"

    private func retryWake(bundleID: String, step: Int) {
        guard step < Self.wakeDelays.count else { isWaking = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeDelays[step]) { [weak self] in
            guard let self else { return }
            guard observedElement != nil else { isWaking = false; return }
            wakeAttempts += 1
            nudgeTree()
            let before = fieldRole
            // refresh may call scheduleWakeRetry again; isWaking is still true,
            // so it is a no-op and the ladder cannot branch.
            refresh(bundleID: bundleID)
            if before == .unknown, fieldRole != .unknown {
                wakeSuccesses += 1
                isWaking = false
                return
            }
            retryWake(bundleID: bundleID, step: step + 1)
        }
    }

    private static func describe(_ status: AXError) -> String {
        switch status {
        case .success: return "успех"
        case .apiDisabled: return "-25211 доступ не выдан нашему процессу"
        case .attributeUnsupported: return "-25205 атрибут не поддерживается"
        case .cannotComplete: return "-25204 приложение не отвечает"
        case .noValue: return "нет значения"
        case .invalidUIElement: return "невалидный элемент"
        default: return "AXError \(status.rawValue)"
        }
    }

    /// - Note: there is no `AXSecureTextField` **role**. A password field is
    ///   always role `AXTextField` with subrole `AXSecureTextField`, and both
    ///   WebKit and Chromium report it that way for `<input type="password">`,
    ///   which is what makes browser passwords detectable at all.
    static func classify(role: String?, subrole: String?) -> FieldRole {
        if subrole == (kAXSecureTextFieldSubrole as String) { return .secure }
        guard let role else { return .unknown }
        switch role {
        case kAXTextFieldRole as String, kAXTextAreaRole as String,
             kAXComboBoxRole as String, kAXSearchFieldSubrole as String:
            return .text
        default:
            // AXWebArea, AXGroup, AXUnknown — Chromium before its tree wakes up.
            // Not a text field as far as we know, and we do not guess.
            return .unknown
        }
    }

    private func publish(_ role: FieldRole) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "—"
        let entry = Observation(app: app, role: lastRole, subrole: lastSubrole, verdict: role)
        if history.last.map({ $0.app != entry.app || $0.role != entry.role || $0.verdict != entry.verdict }) ?? true {
            history.append(entry)
            if history.count > 24 { history.removeFirst() }
        }
        guard role != fieldRole else { return }
        fieldRole = role
        onFocusChanged?(role)
    }
}
