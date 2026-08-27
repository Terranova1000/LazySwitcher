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
    let policies = AppPolicyStore(loadingFrom: .shared)
    let context = ContextStore()
    let replacer = TextReplacer()
    let undo = UndoController()
    let modelStore = ModelStore()
    let feedback = FeedbackStore()

    /// Replacements run here, one at a time.
    ///
    /// They used to go to `DispatchQueue.global`, which is concurrent — so a
    /// second word finishing while the first was still typing interleaved their
    /// backspaces and characters. That is what "it sometimes eats the space
    /// before the word" looks like from the outside. A replacement is a sequence
    /// of events with sleeps between them and is only correct if nothing else is
    /// posting keys at the same time.
    private let applyQueue = DispatchQueue(label: "com.lazyswitcher.apply", qos: .userInitiated)

    /// True while events are being posted. Anything that would start a second
    /// replacement is dropped rather than queued: by the time the first one
    /// finishes, the caret is somewhere else and the second one's idea of what
    /// to delete is stale.
    private var isReplacing = false

    /// Recent words, for settling short ones by their neighbours.
    private var chain = WordChain()
    let chainRescues = AtomicCounter()

    /// Shortest word we will convert on our own. Measured, not guessed: at five
    /// characters false positives are 0.00%, at four they are 0.87%
    /// (eval/report.md). Below five the user has to ask.
    var minimumAutomaticLength: Int { Settings.shared.minimumLength }

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
    let automaticReplacements = AtomicCounter()
    private(set) var lastDecisionNote = "—"

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
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
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
        tap.onBufferInvalidated = { [weak self] _ in
            // The chain is a claim about text sitting on screen in a known
            // place. Once the caret has moved, it is a claim about nothing.
            self?.chain.clear()
        }

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
        M5SelfTest.watchForTrigger(delegate: self)
        tap.setHotkeyStyle(Settings.shared.hotkeyStyle)

        // Only if the user asked for it, and at most weekly.
        UpdateChecker.checkOnScheduleIfEnabled { [weak self] outcome in
            guard case .updateAvailable(let latest, _) = outcome else { return }
            self?.menuBar.showUpdateAvailable(version: latest)
        }
    }

    private func startTapOrExplain() {
        let state = Permissions.current()
        if state.isUsable, tap.start() {
            menuBar.update(permissions: .granted)
            return
        }
        menuBar.update(permissions: state.looksStuck ? .stuck : .missing)
        showOnboarding()
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
        // The user may choose to work where the field type is unknown. It is off
        // by default and the settings screen says plainly what it costs; this is
        // the one place that turns that choice into behaviour.
        if Settings.shared.actInUnidentifiedFields, focus.fieldRole == .unknown {
            hot.fieldRole = .text
        }
        hot.fieldRoleUnavailable = policies.hidesFieldRoles(bundleID)
        if !Settings.shared.automaticEnabled, hot.policy == .automatic {
            hot.policy = .hotkeyOnly
        }
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
            switch verdict {
            case .vetoed(.tooShort):
                // Not allowed to act on its own — but this is exactly the kind of
                // word the next one rescues, so it still has to be scored and
                // remembered. The length rule governs what we may *do*, not what
                // we may *know*.
                lastVetoReason = nil
            case .vetoed(let reason):
                // A safety veto — a password shape, an address, a path. Break the
                // chain: whatever this is, it must not be swept into a run later.
                wordsVetoed.bump()
                lastVetoReason = reason
                chain.clear()
                return
            case .allowed:
                lastVetoReason = nil
            }
            considerAutomatic(word: word,
                              typed: reading.typed,
                              alternative: reading.alternative,
                              sourceLanguage: reading.sourceLanguage,
                              targetLanguage: reading.targetLanguage,
                              target: reading.target,
                              trailing: terminator == Self.spaceKeyCode ? " " : nil)
        }
    }

    /// Everything above has said the word *may* be touched. This decides whether
    /// it *should* be — and it is the only place in the app that acts without
    /// being asked, so the conditions are spelled out rather than combined.
    private func considerAutomatic(word: [KeyRecord],
                                   typed: String,
                                   alternative: String,
                                   sourceLanguage: String,
                                   targetLanguage: String,
                                   target: TISInputSource,
                                   trailing: String?) {
        let hot = context.current
        guard let sourceModel = modelStore.model(for: sourceLanguage),
              let targetModel = modelStore.model(for: targetLanguage) else {
            lastDecisionNote = "нет модели для \(sourceLanguage)→\(targetLanguage)"
            return
        }
        let scorer = Scorer(models: .init(source: sourceModel, target: targetModel))
        let (decision, evidence) = scorer.decide(typed: typed, converted: alternative)

        // The chain is recorded whatever we decide — a word we left alone is
        // exactly the kind the next word may rescue.
        defer {
            chain.append(.init(typed: typed, alternative: alternative,
                               separator: trailing ?? "", evidence: evidence,
                               converted: false))
        }

        guard hot.allowsAutomaticReplacement else { return }

        let longEnough = typed.count >= minimumAutomaticLength
        // A short word may still go if the one before it just went: the run is
        // demonstrably in the wrong layout, so this is no longer a coin flip.
        let inherits = !longEnough
            && chain.previousWasConverted
            && WordChain.mayInherit(evidence)
            && decision != .keep

        guard longEnough || inherits else {
            lastDecisionNote = "«\(typed)»: короче \(minimumAutomaticLength), ждём соседа"
            return
        }
        guard decision == .convert || inherits else {
            lastDecisionNote = String(format: "«%@» %@ Λ=%.2f", typed, "\(decision)", evidence.perCharacter)
            return
        }

        // Now look left: short words we passed over are probably wrong too.
        let rescued = chain.retroactiveCandidates()
        var from = typed + (trailing ?? "")
        var to = alternative + (trailing ?? "")
        for entry in rescued.reversed() {
            from = entry.onScreen + entry.separator + from
            to = entry.alternative + entry.separator + to
        }

        lastDecisionNote = rescued.isEmpty
            ? String(format: "«%@» convert Λ=%.2f%@", typed, evidence.perCharacter, inherits ? " (по соседу)" : "")
            : String(format: "«%@» convert, с ним %d слева", typed, rescued.count)

        automaticReplacements.bump()
        if !rescued.isEmpty { chainRescues.bump() }
        applyRun(from: from, to: to, target: target, marking: rescued.count + 1)
    }

    /// Replaces a run of already-typed text in one operation.
    ///
    /// One operation rather than several on purpose: separate replacements would
    /// each have to be correct about where the caret is after the previous one,
    /// and the whole point of the chain is that these words sit next to each
    /// other, so the run is a single known string.
    private func applyRun(from: String, to: String, target: TISInputSource, marking count: Int) {
        let bundleID = context.currentCold.bundleID
        guard !isReplacing else { note("пропущено: предыдущая замена ещё идёт"); return }
        isReplacing = true
        applyQueue.async { [weak self] in
            guard let self else { return }
            let outcome = replacer.replace(original: from, with: to, in: bundleID)
            DispatchQueue.main.async {
                self.isReplacing = false
                guard outcome.succeeded else { self.note("замена не удалась"); return }
                self.replacementsMade.bump()
                self.note("\(outcome.strategy.rawValue): «\(from)» → «\(to)»")
                self.chain.markConverted(count: count)
                self.undo.arm(original: from, replacement: to, bundleID: bundleID)
                if Settings.shared.switchLayoutAfterReplacement { self.inputSources.select(target) }
                self.playFeedback()
            }
        }
    }

    private func playFeedback() {
        Settings.shared.playFeedbackSound()
        menuBar.flash()
    }

    /// Re-reads anything cached from settings. Cheap, so called on every change
    /// rather than trying to work out which change mattered.
    func settingsDidChange() {
        publishContext(bundleID: apps.bundleID, appName: apps.appName)
        tap.setHotkeyStyle(Settings.shared.hotkeyStyle)
    }

    func showOnboarding() {
        if onboarding == nil { onboarding = OnboardingWindowController(app: self) }
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.showWindow(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
    }

    /// Renders a run of keystrokes in the active layout and in the other one.
    private struct Reading {
        let typed: String
        let alternative: String
        let target: TISInputSource
        let sourceLanguage: String
        let targetLanguage: String
    }

    private func read(_ word: [KeyRecord]) -> Reading? {
        guard let current = InputSourceService.currentLayout(),
              let currentTable = keyMapper.table(for: current),
              let sourceLanguage = InputSourceService.primaryLanguage(of: current) else { return nil }
        let others = InputSourceService.enabledKeyboardLayouts().filter {
            InputSourceService.identifier(of: $0) != currentTable.layoutID
        }
        guard let other = others.first,
              let targetLanguage = InputSourceService.primaryLanguage(of: other),
              let otherTable = keyMapper.table(for: other),
              let typed = keyMapper.render(word, with: currentTable),
              let alternative = keyMapper.render(word, with: otherTable)
        else { return nil }
        return Reading(typed: typed, alternative: alternative, target: other,
                       sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
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
            convertOnHotkey()
        }
    }

    /// What the hotkey acts on, in priority order.
    ///
    /// Selection first: if the user went to the trouble of selecting text, that
    /// is unambiguously what they mean, and it is the only way to fix a whole
    /// sentence typed in the wrong layout.
    private func convertOnHotkey() {
        if let selection = TextSelection.current(), !selection.text.isEmpty {
            convertSelection(selection)
            return
        }
        tap.requestHotkeyTarget { [weak self] target in
            guard let self else { return }
            if !target.inProgress.isEmpty {
                apply(keys: target.inProgress, trailing: nil)
            } else if let committed = target.justCommitted,
                      let terminator = Self.terminatorText(committed.terminator) {
                // Reachable only while nothing at all has happened since the
                // space — the buffer guarantees that, not a stopwatch.
                apply(keys: committed.keys, trailing: terminator)
            } else {
                note("нечего исправлять")
                NSSound.beep()
            }
        }
    }

    /// Only a space can be retyped as text. Tab and Return would have to be
    /// re-sent as keys, and in most apps Return has already done something
    /// irreversible — sent the message, submitted the form.
    private static func terminatorText(_ keyCode: UInt16) -> String? {
        keyCode == spaceKeyCode ? " " : nil
    }

    /// Converts a whole selection, however long, in one go.
    ///
    /// This is the answer to "I wrote a paragraph in the wrong layout". It reads
    /// the selection back into keystrokes, renders them in the other layout and
    /// writes the result over the selection — so spaces, punctuation and case all
    /// come out where they were.
    private func convertSelection(_ selection: TextSelection.Snapshot) {
        guard let current = InputSourceService.currentLayout(),
              let currentTable = keyMapper.table(for: current) else {
            note("не удалось прочитать раскладку"); NSSound.beep(); return
        }
        let others = InputSourceService.enabledKeyboardLayouts().filter {
            InputSourceService.identifier(of: $0) != currentTable.layoutID
        }
        guard let other = others.first, let otherTable = keyMapper.table(for: other) else {
            note("не найдена вторая раскладка"); NSSound.beep(); return
        }

        // Read the text back into the keys that would have produced it, then ask
        // what those keys mean in the other layout.
        guard let keys = keyMapper.keystrokes(of: selection.text, in: currentTable),
              let converted = keyMapper.render(keys, with: otherTable) else {
            note("в выделении есть символы, которых нет в раскладке")
            NSSound.beep()
            return
        }
        guard converted != selection.text else { note("менять нечего"); NSSound.beep(); return }

        let hot = context.current
        // The safety context still applies in full: a selection inside a password
        // field or a terminal is refused like anything else. What is deliberately
        // NOT applied is the per-word shape rules — the user selected a sentence
        // and asked for it, and vetoing it because it contains a full stop would
        // be obtuse.
        guard !hot.isSecureInput else { note("запрещено: включён Secure Input"); NSSound.beep(); return }
        guard hot.policy != .disabled else { note("запрещено: в этом приложении выключено"); NSSound.beep(); return }
        guard hot.fieldRole == .text || hot.allowsExplicitActionDespiteUnknownField else {
            note("запрещено: поле не для обычного текста"); NSSound.beep(); return
        }

        let bundleID = context.currentCold.bundleID
        guard !isReplacing else { NSSound.beep(); return }
        isReplacing = true
        applyQueue.async { [weak self] in
            guard let self else { return }
            // A selection is already highlighted, so typing replaces it — no
            // backspaces, and nothing outside the selection can be touched.
            let ok = TextSelection.replace(selection, with: converted, synthetic: replacer.syntheticSource)
            DispatchQueue.main.async {
                self.isReplacing = false
                guard ok else { self.note("не удалось заменить выделение"); return }
                self.replacementsMade.bump()
                self.note("выделение (\(selection.text.count) симв.) → «\(converted.prefix(24))…»")
                self.tap.clearBufferAfterReplacement()
                self.undo.arm(original: selection.text, replacement: converted, bundleID: bundleID)
                if Settings.shared.switchLayoutAfterReplacement { self.inputSources.select(other) }
                self.playFeedback()
            }
        }
    }

    private static let spaceKeyCode: UInt16 = 0x31

    private func apply(keys: [KeyRecord], trailing: String?,
                       explicit: Bool = true,
                       precomputed: (typed: String, alternative: String, target: TISInputSource)? = nil) {
        let resolved: (typed: String, alternative: String, target: TISInputSource)
        if let precomputed {
            resolved = precomputed
        } else if let reading = read(keys) {
            resolved = (reading.typed, reading.alternative, reading.target)
        } else {
            note("не удалось прочитать слово"); return
        }
        let reading = resolved

        let hot = context.current
        // An explicit request overrides a learned exclusion: the user is asking
        // for this one right now, which is newer information than the fact that
        // they once refused it.
        let learned: Set<String> = (!explicit && feedback.isRejected(reading.typed))
            ? [reading.typed.lowercased()] : []
        let verdict = VetoGate.evaluate(.init(word: reading.typed,
                                              context: hot,
                                              minimumLength: minimumAutomaticLength,
                                              userExclusions: learned,
                                              isExplicitRequest: explicit))
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

        guard !isReplacing else { note("пропущено: предыдущая замена ещё идёт"); return }
        isReplacing = true

        // Off the main thread: synthetic typing sleeps between events, and a
        // ten-letter word is over a hundred milliseconds of it.
        applyQueue.async { [weak self] in
            guard let self else { return }
            let outcome = replacer.replace(original: from, with: to, in: bundleID)
            DispatchQueue.main.async {
                self.isReplacing = false
                guard outcome.succeeded else { self.note("замена не удалась"); return }
                self.replacementsMade.bump()
                self.note("\(outcome.strategy.rawValue): «\(reading.typed)» → «\(reading.alternative)»")
                self.tap.clearBufferAfterReplacement()
                self.undo.arm(original: from, replacement: to, bundleID: bundleID)
                // Switch the layout too, or the next word comes out wrong again
                // and the correction was pointless.
                if Settings.shared.switchLayoutAfterReplacement { self.inputSources.select(reading.target) }
                self.playFeedback()
            }
        }
    }

    private func revert(_ pending: UndoController.Pending) {
        guard !isReplacing else { NSSound.beep(); return }
        isReplacing = true
        applyQueue.async { [weak self] in
            guard let self else { return }
            let outcome = replacer.replace(original: pending.replacement,
                                           with: pending.original,
                                           in: pending.bundleID)
            DispatchQueue.main.async {
                self.isReplacing = false
                guard outcome.succeeded else { self.note("откат не удался"); return }
                self.undosMade.bump()
                // The word the user just rejected. Trimmed of the separator we
                // added, so "ghbdtn " and "ghbdtn" are the same word.
                let word = pending.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                let becamePermanent = self.feedback.recordUndo(of: word)
                self.note(becamePermanent
                          ? "откат: «\(pending.original)». Слово больше не заменяется никогда"
                          : "откат: вернули «\(pending.original)»")
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

    /// Reachable only from the hotkey path, which is where `read` is called.

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

    @objc func openReleasesPage(_ sender: Any?) {
        NSWorkspace.shared.open(UpdateChecker.releasesPage)
    }

    @objc func openAccessibilitySettings(_ sender: Any?) {
        Permissions.openAccessibilitySettings()
    }

    @objc func quit(_ sender: Any?) {
        tap.stop()
        NSApp.terminate(nil)
    }
}
