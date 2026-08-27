import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    let tap = KeyTapService()
    let secureInput = SecureInputMonitor()
    let mouse = MouseMonitor()
    let inputSources = InputSourceService()
    let keyMapper = KeyMapper()
    let apps = AppMonitor()
    let focus = FocusMonitor()
    let policies = AppPolicyStore()
    let context = ContextStore()
    let replacer = TextReplacer()
    let undo = UndoController()

    /// Words seen since launch, and how many we could render in both layouts.
    /// Counts only — the words themselves never leave memory.
    let wordsCommitted = AtomicCounter()
    let wordsConvertible = AtomicCounter()
    let wordsVetoed = AtomicCounter()
    private(set) var lastVetoReason: VetoGate.Reason?
    /// Last word in both readings, for the diagnostics window on screen only.
    private(set) var lastPair: (typed: String, alternative: String)?
    let replacementsMade = AtomicCounter()
    let undosMade = AtomicCounter()
    private(set) var lastReplacementNote = "—"

    /// The word that was just committed, kept so the hotkey can reach back for
    /// it after the user has already pressed space.
    private struct Committed {
        let keys: [KeyRecord]
        let terminator: UInt16
        let at: Date
    }
    private var lastCommitted: Committed?
    private var menuBar: MenuBarController!
    private var diagnostics: DiagnosticsWindowController?
    private var reportTimer: Timer?
    private var permissionTimer: Timer?

    /// XCTest launches the app as a host for the test bundle. In that mode it
    /// must stay inert: a real launch installs an event tap, pops the system
    /// permission dialog and waits on it, which turns a two-second test run into
    /// a two-minute one and makes the result depend on what a human clicks.
    private var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningUnderTests else { return }
        menuBar = MenuBarController(delegate: self)

        secureInput.onChange = { [weak self] enabled in
            guard let self else { return }
            // Mirror it where the tap callback can read it without calling into
            // Carbon, and drop anything we are holding the moment it turns on.
            tap.secureInputMirror.value = enabled ? 1 : 0
            context.setSecureInput(enabled)
            if enabled { tap.wipeVolatileState() }
            menuBar.update(secureInput: enabled)
        }

        // App switch → new process to observe, and a caret that is now elsewhere.
        apps.onAppChanged = { [weak self] pid, bundleID, name in
            guard let self else { return }
            tap.invalidateBuffer(reason: .appChanged)
            focus.observe(pid: pid, bundleID: bundleID)
            publishContext(bundleID: bundleID, appName: name)
        }
        focus.onFocusChanged = { [weak self] _ in
            guard let self else { return }
            tap.invalidateBuffer(reason: .focusChanged)
            publishContext(bundleID: apps.bundleID, appName: apps.appName)
        }
        apps.start()
        secureInput.start()
        tap.secureInputMirror.value = secureInput.isEnabled ? 1 : 0

        // A click can put the caret anywhere; keeping the buffer across one
        // would make our backspaces delete somebody else's text.
        mouse.onClick = { [weak self] in self?.tap.invalidateBuffer(reason: .mouseClick) }
        mouse.start()

        inputSources.onLayoutChanged = { [weak self] in self?.keyMapper.invalidate() }
        inputSources.startWatching()

        tap.onWordCommitted = { [weak self] word, terminator in
            self?.evaluate(word, terminator: terminator)
        }
        tap.onHotkey = { [weak self] event in self?.handle(hotkey: event) }

        startTapOrExplain()
        // Deliberately not opened at launch. A menu-bar agent that throws a
        // window in your face is bad manners, and worse, ours kept stealing
        // focus back from the app being tested. The report file is written
        // either way; the window is available from the menu.

        // M0 scaffolding — remove at M1.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            M0Report.write(tap: tap, secureInput: secureInput)
        }
        RunLoop.main.add(t, forMode: .common)
        reportTimer = t
        M0Report.write(tap: tap, secureInput: secureInput)
        M0TimeoutSweep.watchForTrigger(tap: tap)
        M4SelfTest.watchForTrigger(delegate: self)
    }

    private func startTapOrExplain() {
        let state = Permissions.current()
        if state.isUsable, tap.start() {
            menuBar.update(permissions: .granted)
            return
        }
        menuBar.update(permissions: state.looksStuck ? .stuck : .missing)
        if !state.looksStuck { Permissions.request() }
        watchForPermission()
    }

    /// Poll until access appears, then start without asking the user to relaunch.
    ///
    /// Granting Accessibility often does take effect live, but nothing notifies us:
    /// `com.apple.accessibility.api` is not delivered when the user adds the app to
    /// the list, only in some removal cases. So we watch `CGPreflight*`, which is
    /// cheap, rather than trusting a notification that may never come.
    private func watchForPermission() {
        guard permissionTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            guard Permissions.current(runProbe: false).isUsable else { return }
            if tap.start() {
                menuBar.update(permissions: .granted)
                timer.invalidate()
                permissionTimer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    private func publishContext(bundleID: String, appName: String) {
        var hot = HotContext()
        hot.isSecureInput = secureInput.isEnabled
        hot.policy = policies.policy(for: bundleID)
        hot.fieldRole = focus.fieldRole
        hot.fieldRoleUnavailable = policies.hidesFieldRoles(bundleID)
        context.publish(hot: hot, cold: ColdContext(bundleID: bundleID, appName: appName))
    }

    /// M1–M3 end to end: a word ended, check it is allowed to be touched at all,
    /// then render it in the active layout and in the other one. Deciding which
    /// reading is right is M5; applying the change is M4.
    private func evaluate(_ word: [KeyRecord], terminator: UInt16) {
        wordsCommitted.bump()
        guard let reading = read(word) else { return }
        wordsConvertible.bump()

        // The veto runs on the rendered word, before any scoring — it is cheap
        // and it is the layer that keeps us out of trouble.
        let verdict = VetoGate.evaluate(.init(word: reading.typed, context: context.current))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            lastPair = (typed: reading.typed, alternative: reading.alternative)
            lastCommitted = Committed(keys: word, terminator: terminator, at: Date())
            // Any new typing means the previous replacement is no longer the
            // thing sitting in front of the caret.
            undo.invalidate()
            if case .vetoed(let reason) = verdict {
                wordsVetoed.bump()
                lastVetoReason = reason
            } else {
                lastVetoReason = nil
            }
            // Automatic replacement waits for the detector (M5). Until then the
            // hotkey is the only thing that changes text, which also makes this
            // the safest possible first version.
        }
    }

    /// Renders a run of keystrokes in the active layout and in the other one.
    private func read(_ word: [KeyRecord]) -> (typed: String, alternative: String, target: TISInputSource)? {
        guard let current = InputSourceService.currentLayout(),
              let currentTable = keyMapper.table(for: current) else { return nil }
        let others = InputSourceService.enabledKeyboardLayouts().filter {
            InputSourceService.identifier(of: $0) != currentTable.layoutID
        }
        guard let other = others.first,
              let otherTable = keyMapper.table(for: other),
              let typed = keyMapper.render(word, with: currentTable),
              let alternative = keyMapper.render(word, with: otherTable)
        else { return nil }
        return (typed, alternative, other)
    }

    // MARK: - Hotkey

    private func handle(hotkey event: HotkeyDetector.Event) {
        switch event {
        case .panicToggle:
            NSSound.beep()                      // M6 wires the real pause
        case .doubleTapShift:
            // Undo first: pressing the hotkey right after a replacement means
            // "that was wrong", not "do it again".
            if undo.isAvailable, let pending = undo.consume() {
                revert(pending)
                return
            }
            convertLastWord()
        }
    }

    private func convertLastWord() {
        // The in-progress word if there is one; otherwise the word the user
        // just finished with a space.
        tap.requestCurrentWord { [weak self] inProgress in
            guard let self else { return }
            if !inProgress.isEmpty {
                apply(keys: inProgress, trailing: nil)
            } else if let committed = lastCommitted,
                      Date().timeIntervalSince(committed.at) < 30,
                      committed.terminator == Self.spaceKeyCode {
                apply(keys: committed.keys, trailing: " ")
            } else {
                note("нечего исправлять")
                NSSound.beep()
            }
        }
    }

    private static let spaceKeyCode: UInt16 = 0x31

    private func apply(keys: [KeyRecord], trailing: String?) {
        guard let reading = read(keys) else { note("не удалось прочитать слово"); return }

        let hot = context.current
        let verdict = VetoGate.evaluate(.init(word: reading.typed,
                                              context: hot,
                                              userExclusions: [],
                                              isExplicitRequest: true))
        if case .vetoed(let reason) = verdict {
            wordsVetoed.bump()
            lastVetoReason = reason
            note("запрещено: \(reason.rawValue)")
            NSSound.beep()
            return
        }

        let bundleID = context.currentCold.bundleID
        let from = reading.typed + (trailing ?? "")
        let to = reading.alternative + (trailing ?? "")

        // Off the main thread: synthetic typing sleeps between events, and a
        // ten-letter word is over a hundred milliseconds of it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = replacer.replace(original: from, with: to, in: bundleID)
            DispatchQueue.main.async {
                guard outcome.succeeded else { self.note("замена не удалась"); return }
                self.replacementsMade.bump()
                self.note("\(outcome.strategy.rawValue): «\(reading.typed)» → «\(reading.alternative)»")
                self.tap.clearBufferAfterReplacement()
                self.undo.arm(original: from, replacement: to, bundleID: bundleID)
                // Switch the layout too, or the next word comes out wrong again
                // and the correction was pointless.
                self.inputSources.select(reading.target)
                NSSound(named: "Tink")?.play()
            }
        }
    }

    private func revert(_ pending: UndoController.Pending) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = replacer.replace(original: pending.replacement,
                                           with: pending.original,
                                           in: pending.bundleID)
            DispatchQueue.main.async {
                guard outcome.succeeded else { self.note("откат не удался"); return }
                self.undosMade.bump()
                self.note("откат: вернули «\(pending.original)»")
                self.tap.clearBufferAfterReplacement()
                NSSound(named: "Pop")?.play()
            }
        }
    }

    /// Entry point for `M4SelfTest`, which needs to drive a replacement without
    /// a keyboard. Same code path as the hotkey, no shortcuts.
    func applyForSelfTest(keys: [KeyRecord]) {
        apply(keys: keys, trailing: nil)
    }

    /// Re-reads the focused element and republishes context. The self-test needs
    /// it because it brings an app forward that may already have been frontmost,
    /// in which case no activation notification fires and the cached role is
    /// whatever it was before.
    func refreshContextForSelfTest() {
        focus.refresh(bundleID: apps.bundleID)
        publishContext(bundleID: apps.bundleID, appName: apps.appName)
    }

    func readingForSelfTest(keys: [KeyRecord]) -> (typed: String, alternative: String)? {
        guard let reading = read(keys) else { return nil }
        return (reading.typed, reading.alternative)
    }

    private func note(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.lastReplacementNote = text }
    }

    @objc func showDiagnostics(_ sender: Any?) {
        if diagnostics == nil {
            diagnostics = DiagnosticsWindowController(tap: tap, secureInput: secureInput)
        }
        NSApp.activate(ignoringOtherApps: true)
        diagnostics?.showWindow(nil)
    }

    @objc func openAccessibilitySettings(_ sender: Any?) {
        Permissions.openAccessibilitySettings()
    }

    @objc func quit(_ sender: Any?) {
        tap.stop()
        NSApp.terminate(nil)
    }
}
