import AppKit
import Carbon.HIToolbox

/// Enumerating, reading and switching keyboard layouts.
///
/// **Every function here must be called on the main thread.** Text Input Sources
/// is one of the HIToolbox APIs that asserts this internally, and the failure is
/// not a warning or a wrong answer — `dispatch_assert_queue` traps and the
/// process dies:
///
///     _dispatch_assert_queue_fail
///     islGetInputSourceListWithAdditions
///     TSMGetInputSourceProperty
///     InputSourceService.stringProperty(_:_:)
///
/// That crash happened twice in real use before it was found, from the decide
/// queue, which is why callers off the main thread read `LayoutPair` instead.
/// The precondition below turns a crash in somebody's hands into a crash in the
/// test suite, at the call site that caused it.
final class InputSourceService {

    /// Both layouts and everything needed to reason about them, captured on the
    /// main thread so other queues can read it without touching TIS.
    ///
    /// A value type all the way down: `KeyMapper.Table` is a struct of strings,
    /// so a copy is a copy and there is nothing to race on. The `TISInputSource`
    /// references are carried only to hand back to `select`, which itself runs
    /// on the main thread.
    struct LayoutPair {
        let source: KeyMapper.Table
        let target: KeyMapper.Table
        let sourceLanguage: String
        let targetLanguage: String
        let targetInputSource: TISInputSource
    }

    private static func requireMainThread(_ function: StaticString = #function) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
    }

    /// When the user last switched layouts by hand. We stay out of their way for
    /// a couple of seconds afterwards, or we end up in a switching war with them
    /// and with apps that manage the input source themselves.
    private(set) var lastManualSwitch: Date = .distantPast
    private var lastOwnSwitch: Date = .distantPast
    private var suppressNextChangeNotification = false

    var onLayoutChanged: (() -> Void)?

    /// Counters for diagnosing "the layout sometimes does not switch". Numbers
    /// only — nothing here says anything about what was typed.
    let performedSwitches = AtomicCounter()
    let refusedSwitches = AtomicCounter()
    let failedSwitches = AtomicCounter()
    private(set) var lastSwitchError = 0
    /// Which layout we last asked for, and which one somebody else moved to.
    /// The pair is what distinguishes "they undid us" from "the layout changed".
    private var lastSelectedTarget: String?
    private var lastManualTarget: String?

    // MARK: - Reading

    /// Every enabled keyboard layout.
    ///
    /// `includeAllInstalled: false` on purpose — passing true pulls in every
    /// layout on the system and noticeably grows memory. Note also that
    /// `kTISPropertyInputSourceIsEnableCapable` is NOT the filter for this: it
    /// means "may be enabled", not "is enabled".
    static func enabledKeyboardLayouts() -> [TISInputSource] {
        requireMainThread()
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.filter { source in
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable),
                  CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
            else { return false }
            return true
        }
    }

    /// The layout actually in effect.
    ///
    /// Three functions claim to answer this and they differ:
    ///   TISCopyCurrentKeyboardInputSource      — what is selected, may be an input method
    ///   TISCopyCurrentKeyboardLayoutInputSource — the layout in force, including the
    ///                                             one underneath an input method  ← ours
    ///   TISCopyCurrentASCIICapableKeyboardLayoutInputSource — last ASCII-capable one
    static func currentLayout() -> TISInputSource? {
        requireMainThread()
        return TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    /// TISGetInputSourceProperty is a *Get* function: the result is not owned and
    /// must not be released, hence takeUnretainedValue throughout.
    static func identifier(of source: TISInputSource) -> String? {
        requireMainThread()
        return stringProperty(source, kTISPropertyInputSourceID)
    }

    static func localizedName(of source: TISInputSource) -> String? {
        requireMainThread()
        return stringProperty(source, kTISPropertyLocalizedName)
    }

    static func primaryLanguage(of source: TISInputSource) -> String? {
        requireMainThread()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let langs = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
        else { return nil }
        return langs.first
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    // MARK: - Switching

    /// Switches layouts, unless the user just did it themselves.
    @discardableResult
    func select(_ source: TISInputSource) -> Bool {
        Self.requireMainThread()

        // Already where we wanted to be. Nothing to do, and — the part that
        // matters — nothing to back off from.
        //
        // macOS switches the layout on its own when text in another script
        // appears: the moment our replacement types Cyrillic, the system may
        // select the Russian layout by itself. That arrives as an ordinary
        // change notification, indistinguishable from somebody pressing the
        // layout key, so we recorded it as a manual switch and refused to touch
        // the layout for the next two seconds — every single time, because it
        // happened on every replacement.
        //
        // Measured before the fix: four refusals, zero switches performed, while
        // the layout was visibly changing. We were being blamed for work the
        // system was doing and blocked from doing it ourselves.
        if let current = Self.currentLayout(),
           Self.identifier(of: current) == Self.identifier(of: source) {
            return true
        }

        let now = Date()
        // Never twice in quick succession.
        guard now.timeIntervalSince(lastOwnSwitch) > 0.3 else { refusedSwitches.bump(); return false }

        // Back off only from an actual fight — somebody undoing *our* switch —
        // and only while it is still happening.
        //
        // The comparison here is against **now**, and getting that wrong was a
        // real defect: the previous version compared the two stored timestamps
        // to each other. Once a layout change landed within two seconds of our
        // own switch, both timestamps froze, their difference stayed under two
        // seconds forever, and every later switch was refused — permanently,
        // because `lastOwnSwitch` only advances on a switch that succeeds.
        //
        // From the outside that was "the layout stops switching, and after a
        // while it starts working again": it recovered only when some later
        // manual switch happened to land more than two seconds past a stale
        // `lastOwnSwitch`. A guard that latches is worse than no guard, because
        // it fails in the direction nobody checks.
        //
        // Note this also fires for layout changes we did not cause and the user
        // did not make: macOS restores a per-application input source when focus
        // moves, and that arrives as an ordinary change notification. Backing
        // off from it for two seconds is right — it is exactly the case where
        // switching again would fight the system — but only for two seconds.
        // And back off only from an actual undo: a change that moved *away*
        // from the layout we ourselves selected. A change to something else
        // entirely is not a fight with us, and treating every change as one is
        // how the previous version refused to work at all.
        if lastManualSwitch > lastOwnSwitch,
           now.timeIntervalSince(lastManualSwitch) < 2.0,
           lastManualTarget != nil,
           lastManualTarget != lastSelectedTarget {
            refusedSwitches.bump()
            return false
        }

        suppressNextChangeNotification = true
        let status = TISSelectInputSource(source)
        guard status == noErr else {
            suppressNextChangeNotification = false
            failedSwitches.bump()
            lastSwitchError = Int(status)
            return false
        }
        lastOwnSwitch = now
        lastSelectedTarget = Self.identifier(of: source)
        performedSwitches.bump()
        return true
    }

    // MARK: - Watching

    func startWatching() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<InputSourceService>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .handleLayoutChange()
            },
            kTISNotifySelectedKeyboardInputSourceChanged,
            nil,
            .deliverImmediately
        )
    }

    func stopWatching() {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func handleLayoutChange() {
        if suppressNextChangeNotification {
            suppressNextChangeNotification = false
        } else {
            lastManualSwitch = Date()
            lastManualTarget = Self.currentLayout().flatMap { Self.identifier(of: $0) }
        }
        onLayoutChanged?()
    }

    /// Clears a stuck expectation.
    ///
    /// `suppressNextChangeNotification` waits for a notification that normally
    /// arrives in milliseconds. If it never does — the switch was coalesced, the
    /// session changed underneath us — the flag stays set and the next genuine
    /// manual switch is mistaken for ours. Cheap to reset on a timer; expensive
    /// to debug if left.
    func clearStaleExpectation() {
        guard suppressNextChangeNotification else { return }
        guard Date().timeIntervalSince(lastOwnSwitch) > 3 else { return }
        suppressNextChangeNotification = false
    }
}
