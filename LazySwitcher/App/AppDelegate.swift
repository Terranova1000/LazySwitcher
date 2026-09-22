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

    /// Panic pause. Promised in the menu, in Settings and in the onboarding, and
    /// until now it only played a beep — the gesture people reach for when
    /// something has gone wrong did nothing at all.
    private(set) var isPaused = false

    /// Recent words, for settling short ones by their neighbours.
    private var chain = WordChain()

    /// Layouts, captured on the main thread for the decide queue to read.
    ///
    /// Rebuilt when the layout changes, not on every word: building it walks
    /// 128 key codes through `UCKeyTranslate` twice, which is cheap but not free,
    /// and — the actual reason — it touches TIS, which may only happen here.
    private var layouts: InputSourceService.LayoutPair?
    private var layoutsLock = os_unfair_lock_s()
    /// Which snapshot is in force, and the one before it.
    ///
    /// Keystrokes carry the number of the layout they were typed in, so a word
    /// that straddles a change can still be read exactly as it appears on
    /// screen — see `KeyRecord.layout`.
    private var layoutEpoch: UInt32 = 0
    private var previousLayouts: InputSourceService.LayoutPair?
    private var previousEpoch: UInt32 = 0
    /// Whether the change into the current layout was one we asked for.
    ///
    /// It decides how much the stamps on keystrokes are worth. Our own switches
    /// are timed to within a few milliseconds, because we poll for them; a
    /// change somebody else made reaches us through a notification that has
    /// been seen to arrive a quarter of a second late, by which time keys typed
    /// in the new layout are already stamped with the old one. Trusting those
    /// stamps would invent seams that are not there and cost corrections.
    private var currentEpochIsOurs = false
    private var awaitingOwnSwitch = false

    var currentLayouts: InputSourceService.LayoutPair? {
        os_unfair_lock_lock(&layoutsLock)
        defer { os_unfair_lock_unlock(&layoutsLock) }
        return layouts
    }

    /// The snapshot plus the numbering, read as one — asking twice could see a
    /// layout change land in between.
    private func layoutSnapshot() -> LayoutSnapshot? {
        os_unfair_lock_lock(&layoutsLock)
        defer { os_unfair_lock_unlock(&layoutsLock) }
        guard let layouts else { return nil }
        return LayoutSnapshot(pair: layouts, epoch: layoutEpoch, previous: previousLayouts,
                              previousEpoch: previousEpoch, epochIsOurs: currentEpochIsOurs)
    }

    private struct LayoutSnapshot {
        let pair: InputSourceService.LayoutPair
        let epoch: UInt32
        let previous: InputSourceService.LayoutPair?
        let previousEpoch: UInt32
        /// See `currentEpochIsOurs`.
        let epochIsOurs: Bool
    }
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
    /// Human-readable trace of the last action and the last decision.
    ///
    /// **These must never contain typed text.** They are shown on screen *and*
    /// written to the debug report on disk, and rule 1 grants no debug
    /// exception: "ни в файл, ни в UserDefaults, ни в крэш-репорт, ни в os_log
    /// (даже в debug)". They used to interpolate the word itself, which made the
    /// report a rolling record of what the user was typing — while a comment in
    /// that very file claimed the opposite.
    ///
    /// What goes here instead: lengths, verdicts, Λ, strategy names. Enough to
    /// debug a decision, nothing to reconstruct a sentence from.
    private(set) var lastReplacementNote = "—"
    let automaticReplacements = AtomicCounter()
    private(set) var lastDecisionNote = "—"

    /// Last few decisions, so "it did not work just now" can be answered with
    /// what the app actually decided instead of a guess. Lengths and verdicts
    /// only — never the words themselves (rule 1).
    private(set) var decisionLog: [String] = []
    private func logDecision(_ line: String) {
        lastDecisionNote = line
        decisionLog.append(line)
        if decisionLog.count > 15 { decisionLog.removeFirst() }
    }
    /// Words we could not even read, and why. The counter matters more than it
    /// looks: a non-zero value here means the app is silently doing nothing.
    let unreadableWords = AtomicCounter()
    var hasLayoutPair: Bool { currentLayouts != nil }

    /// The word that was just committed, kept so the hotkey can reach back for
    /// it after the user has already pressed space.
    private struct Committed {
        let keys: [KeyRecord]
        let terminator: KeyRecord
        let at: Date
    }
    private var lastCommitted: Committed?
    private var menuBar: MenuBarController!
    /// Read-only access for the settings window, which reports an update it
    /// found so the menu bar can show it too.
    var menuBarController: MenuBarController { menuBar }
    #if DEBUG
    private var diagnostics: DiagnosticsWindowController?
    #endif
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    private var reportTimer: Timer?
    private var layoutSweepTimer: Timer?
    private var layoutWatchTimer: Timer?
    private var permissionTimer: Timer?

    /// XCTest launches the app as a host for the test bundle. In that mode it
    /// must stay inert: a real launch installs an event tap, pops the system
    /// permission dialog and waits on it, which turns a two-second test run into
    /// a two-minute one and makes the result depend on what a human clicks.
    private var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    /// Opening the application again, while it is already running, opens
    /// settings.
    ///
    /// A menu-bar application has exactly one way in, and when that way is
    /// missing — the icon did not appear, the menu bar is full, the item was
    /// dragged out — the application is running with no way to reach it, quit
    /// it, or find out what is wrong. Double-clicking it in Applications is what
    /// a person tries next, and until now that did nothing at all.
    ///
    /// It also re-asserts the status item, in case the icon is the thing that
    /// went missing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !isRunningUnderTests else { return true }
        menuBar.reassert()
        showSettings(nil)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningUnderTests else { return }
        menuBar = MenuBarController(delegate: self)
        subscribeToWake()
        SupportPrompt.noteLaunch()
        // Read before anything else can change it: the check records the version
        // it saw, so asking twice would answer false the second time.
        let hasNewsToShow = ReleaseNotes.shouldPresentAutomatically()

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
            chain.clear()
            undo.invalidate()
            tap.invalidateBuffer(reason: .appChanged)
            focus.observe(pid: pid, bundleID: bundleID)
            publishContext(bundleID: bundleID, appName: name)

            // Re-read the layouts: macOS restores a per-application input source
            // when you switch applications, so the layout we are in can change
            // without anybody touching the layout key.
            //
            // Nothing here used to do that. If the change notification did not
            // reach us — or reached us before the switch had finished — the
            // snapshot went on describing the previous application's layout, and
            // every word after that was rendered through the wrong table: both
            // readings came out as nonsense, neither scored, and the word was
            // dropped in silence.
            //
            // From the outside that is "it does not work in a new chat until I
            // switch the language once" — switching the language by hand is what
            // finally rebuilt the snapshot.
            //
            // Deferred a moment because the restoration is not finished when the
            // activation notification arrives; asked immediately, TIS still
            // answers with the layout we are leaving.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.refreshLayouts()
            }
        }
        focus.onFocusChanged = { [weak self] _, caretMoved in
            guard let self else { return }
            // Only a real move invalidates what we know about the text. Learning
            // that the field we are already in is a text field, rather than the
            // web area we first saw, changes nothing about where the caret is.
            if caretMoved {
                chain.clear()
                undo.invalidate()
                tap.invalidateBuffer(reason: .focusChanged)
            }
            publishContext(bundleID: apps.bundleID, appName: apps.appName)
        }
        apps.start()
        secureInput.start()
        tap.secureInputMirror.value = secureInput.isEnabled ? 1 : 0

        // A click can put the caret anywhere; keeping the buffer across one
        // would make our backspaces delete somebody else's text.
        mouse.onClick = { [weak self] in
            guard let self else { return }
            chain.clear()
            undo.invalidate()
            tap.invalidateBuffer(reason: .mouseClick)

            // A click is usually somebody putting the caret where they are about
            // to type, so it is the right moment to find out what they clicked
            // into — before the first word rather than after it.
            //
            // Deferred a moment: asked immediately, the application answers about
            // the field the caret has just left. Rate-limited because a click can
            // arrive as fast as somebody can press the button, and each question
            // is a round trip into another process.
            guard Date().timeIntervalSince(lastClickFieldRetry) > 0.4 else { return }
            lastClickFieldRetry = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, !apps.bundleID.isEmpty,
                      !policies.hidesFieldRoles(apps.bundleID) else { return }
                focus.refresh(bundleID: apps.bundleID, startsWakeLadder: false)
                publishContext(bundleID: apps.bundleID, appName: apps.appName)
            }
        }
        mouse.start()

        inputSources.onLayoutChanged = { [weak self] in
            guard let self else { return }
            noteLayoutArrived()
            keyMapper.invalidate()
            refreshLayouts()
        }
        inputSources.startWatching()
        refreshLayouts()

        // Heartbeat.
        //
        // Everything else in this app is driven by notifications, and one that
        // does not arrive leaves the state depending on it wrong for the rest of
        // the session. That is exactly the shape of the complaint we could not
        // reproduce: "it does not work, then I do something, and after that it
        // works" — the something being whatever finally delivered the missing
        // notification.
        //
        // So once a second we check the few things that must hold for the app to
        // do anything at all, and put them right if they do not. Cheap enough to
        // be unnoticeable, and it turns a session-long failure into a one-second
        // one.
        let sweep = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.heartbeat()
        }
        RunLoop.main.add(sweep, forMode: .common)
        layoutSweepTimer = sweep

        // And a faster one, which does nothing at all unless somebody is typing.
        let layoutWatch = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.watchLayoutWhileTyping()
        }
        RunLoop.main.add(layoutWatch, forMode: .common)
        layoutWatchTimer = layoutWatch

        tap.onWordCommitted = { [weak self] word, terminator in
            self?.evaluate(word, terminator: terminator)
        }
        tap.onHotkey = { [weak self] event in self?.handle(hotkey: event) }
        tap.onBufferInvalidated = { [weak self] reason in
            guard let self else { return }
            // Both the chain and the undo are claims about text sitting on
            // screen in a known place. Once the caret has moved — a click, a
            // focus change, an app switch, an arrow key — they are claims about
            // nothing, and acting on them deletes whatever is there instead.
            //
            // With one exception: the reset we perform ourselves right after a
            // replacement. That one arrives through the same channel, on the
            // main queue, a moment after `undo.arm` — so the undo was armed and
            // then immediately destroyed by our own housekeeping. The hotkey's
            // undo has therefore never worked, for as long as it has existed.
            guard reason != .replacementApplied else { chain.clear(); return }
            chain.clear()
            undo.invalidate()
        }

        startTapOrExplain()
        showWelcomeIfFirstRun()
        // Deliberately not opened at launch. A menu-bar agent that throws a
        // window in your face is bad manners, and worse, ours kept stealing
        // focus back from the app being tested. The report file is written
        // either way; the window is available from the menu.

        // Debug scaffolding. Compiled out of Release entirely — these watch for
        // trigger files and some of them can synthesise keystrokes, which is a
        // useful tool during development and an attack surface in a shipped app.
        #if DEBUG
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
        #endif
        tap.setHotkeyStyle(Settings.shared.hotkeyStyle)
        presentWhatsNewIfUpdated(hasNewsToShow)

        // Only if the user asked for it, and at most weekly.
        UpdateChecker.checkOnScheduleIfEnabled { [weak self] outcome in
            guard case .updateAvailable(let latest, _) = outcome else { return }
            self?.menuBar.showUpdateAvailable(version: latest)
        }
        // And once, quietly, a few seconds after launch — long enough not to
        // compete with everything else starting up. Still only when asked for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard Settings.shared.checkUpdatesAutomatically else { return }
            UpdateChecker.check { outcome in
                guard case .updateAvailable(let latest, _) = outcome else { return }
                self?.menuBar.showUpdateAvailable(version: latest)
            }
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

    /// After an update, and only then. Deferred a moment so it lands after the
    /// menu bar and any permission window have settled — arriving on top of the
    /// screen that is asking for Accessibility would bury the more important of
    /// the two.
    private func presentWhatsNewIfUpdated(_ shouldShow: Bool) {
        guard shouldShow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, onboarding == nil else { return }
            presentWhatsNew(automatic: true)
        }
    }

    /// Shown once, on the very first launch, even when permissions are already
    /// in place — somebody who granted access before the app ever ran has still
    /// never been told what it does.
    private func showWelcomeIfFirstRun() {
        guard !Settings.shared.hasSeenWelcome else { return }
        showOnboarding()
    }

    /// Poll until access appears, then start without asking the user to relaunch.
    ///
    /// Granting Accessibility often does take effect live, but nothing notifies us:
    /// `com.apple.accessibility.api` is not delivered when the user adds the app to
    /// the list, only in some removal cases. So we watch `CGPreflight*`, which is
    /// cheap, rather than trusting a notification that may never come.
    private func watchForPermission() {
        guard permissionTimer == nil else { return }
        // Backs off and eventually stops. Polling once a second forever is what
        // a background agent should never do: if the user is not going to grant
        // access, we would spend the rest of the login session asking. After a
        // few minutes the onboarding window is the thing that will notice.
        //
        // Watching `AXIsProcessTrusted()` and not `CGPreflight*`, which is the
        // whole point of this rewrite. `CGPreflight*` answers from a per-process
        // cache that is created on first use and never refreshed (Н6, measured:
        // the poll kept answering "no" indefinitely while the checkbox was on,
        // and a restart answered "yes" at once). An earlier version of this timer
        // polled exactly that cached value, so in a process that started without
        // access it could not ever have succeeded — it ran for five minutes and
        // gave up, and the app stayed silently dead until the next launch.
        //
        // `AXIsProcessTrusted()` has the opposite flaw — it keeps saying true
        // after access is revoked — but it does turn true when access is granted,
        // which is the only transition this timer exists to catch.
        // Remembered now, before anything can change it: a restart only helps if
        // access arrived *after* we launched, because the only thing a restart
        // fixes is our own stale CGPreflight cache. If we were already trusted
        // when this timer started and the tap still will not open, the cause is
        // something a restart cannot touch — and restarting anyway would put the
        // app in a loop, launching a fresh copy every second forever.
        let trustedAtStart = AXIsProcessTrusted()
        var elapsed = 0.0
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            elapsed += 1
            guard AXIsProcessTrusted() else {
                // Nobody granted anything. Stop asking after a few minutes, but
                // leave the app able to notice later: onboarding and the menu
                // both re-check on demand.
                if elapsed > 300 {
                    timer.invalidate()
                    permissionTimer = nil
                }
                return
            }
            timer.invalidate()
            permissionTimer = nil
            let last = UserDefaults.standard.double(forKey: AppDelegate.relaunchStampKey)
            let since = last == 0 ? .greatestFiniteMagnitude
                                  : Date().timeIntervalSince1970 - last
            switch PermissionRecovery.decide(trusted: true,
                                             trustedAtStart: trustedAtStart,
                                             tapStarted: tap.start(),
                                             alreadyRelaunched: hasRelaunchedForPermissions,
                                             secondsSinceLastRelaunch: since,
                                             elapsed: elapsed) {
            case .granted:
                menuBar.update(permissions: .granted)
            case .relaunch:
                relaunchForFreshPermissionCache()
            case .stuck:
                menuBar.update(permissions: .stuck)
            case .keepWaiting, .giveUp:
                break
            }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    /// Notices that the tap has stopped listening, and rebuilds it.
    ///
    /// The tap has its own watchdog, which handles the ordinary failures —
    /// macOS disabling the tap for being slow, or for user input. What it cannot
    /// handle is its own thread going away: the watchdog is a timer on that
    /// thread's run loop, so if the loop stops, the thing that would have
    /// noticed stops with it. From outside, that looks exactly like the
    /// complaint: the application is running, the icon is there, and nothing
    /// responds — not even the hotkey, because the hotkey arrives through the
    /// same tap as everything else.
    ///
    /// So the tap thread publishes a tick every five seconds, and this watches
    /// for it to stop advancing — in awake time, and asking the thread before
    /// replacing it. `TapLiveness` explains why both matter: the version that
    /// measured silence on the wall clock restarted healthy taps after sleep,
    /// and a restart is how the second tap got in.
    private func ensureTapIsAlive() {
        guard tap.isRunning else { retryStartAfterFailure(); return }

        switch tapLiveness.observe(tick: tap.watchdogTick.value,
                                   now: ProcessInfo.processInfo.systemUptime) {
        case .none:
            return
        case .probe:
            tapProbes.bump()
            tap.checkAlive()
            return
        case .restart:
            break
        }
        tapRestarts.bump()
        if tap.restart() {
            tap.setHotkeyStyle(Settings.shared.hotkeyStyle)
            // Everything typed while the tap was gone is unknown to us.
            tap.invalidateBuffer(reason: .caretMoved)
            note("перехват событий пересоздан — поток перестал отвечать")
        } else {
            menuBar.update(permissions: .missing)
            note("перехват событий не удалось пересоздать")
        }
    }

    /// Starts a new copy of ourselves and steps aside.
    ///
    /// The only way to get a `CGPreflight*` cache that reflects a grant made
    /// after launch (Н6). Silent on purpose: asking the user to quit and reopen
    /// an app they just gave permission to is a bad first impression, and every
    /// tool in this category either does this or makes the user do it by hand.
    private func relaunchForFreshPermissionCache() {
        // Belt and braces over the reasoning at the call site. Whatever else is
        // true, this process restarts itself at most once, and only if the last
        // restart was not a moment ago — so no path anyone adds later can turn
        // this into a launch loop.
        hasRelaunchedForPermissions = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: AppDelegate.relaunchStampKey)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Everything we believe about other processes is suspect after the machine
    /// has slept, so all of it is derived again.
    ///
    /// The event tap revives itself (`KeyTapService` watches the same
    /// notifications), but it was the only thing that did. The focused field,
    /// the keyboard layouts, the accessibility observer — all of them are
    /// answers other processes gave us before the machine slept, and none of
    /// them is re-asked on its own, because waking up changes nothing that any
    /// of them listens for: the application in front afterwards is the same one
    /// as before, so no activation notification is sent.
    ///
    /// Each step here is cheap and safe to repeat, so this deliberately re-does
    /// everything rather than trying to work out what actually broke.
    private func subscribeToWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.didWakeNotification,
                                          NSWorkspace.sessionDidBecomeActiveNotification,
                                          NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.rederiveEverything()
            }
        }
    }

    #if DEBUG
    /// Lets the wake path be exercised without actually sleeping the machine.
    ///
    /// Scaffolding: `scripts/audit-release.sh` fails the build if this string
    /// survives into a release bundle.
    private func checkWakeTrigger() {
        let url = M0Report.url.deletingLastPathComponent().appendingPathComponent("m0-wake")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        rederiveEverything()
    }
    #endif

    private func rederiveEverything() {
        // Whatever was typed around the sleep, we did not see all of it.
        chain.clear()
        undo.invalidate()
        tap.invalidateBuffer(reason: .caretMoved)

        apps.resync()
        refreshLayouts()
        if !apps.bundleID.isEmpty {
            focus.reobserve(pid: apps.pid, bundleID: apps.bundleID)
            focus.refresh(bundleID: apps.bundleID)
            publishContext(bundleID: apps.bundleID, appName: apps.appName)
        }
        menuBar.reassert()
        wakeRecoveries += 1
        note("пробуждение — состояние собрано заново")
    }

    private(set) var wakeRecoveries = 0

    /// Puts right whatever quietly went wrong.
    ///
    /// Deliberately not clever: it re-derives state rather than working out why
    /// the state is missing. Each check is cheap, and each thing being absent
    /// means the app does nothing while appearing to run.
    private func heartbeat() {
        // Before anything else: the icon is the only way to reach this
        // application at all, so an icon that has gone missing is not a cosmetic
        // problem — it is the application becoming unreachable while still
        // running. Two lines to re-assert it, once a second.
        menuBar.ensureVisible()
        ensureTapIsAlive()
        #if DEBUG
        checkWakeTrigger()
        #endif
        inputSources.clearStaleExpectation()
        // Who is in front is the state most likely to be silently wrong, and the
        // cheapest to re-derive.
        apps.resync()

        // An observer that was never created is not a permanent condition. The
        // usual cause is asking too early — at login, before the accessibility
        // subsystem answers — and the cure is simply to ask again.
        if !focus.hasObserver, apps.pid != 0, !apps.bundleID.isEmpty,
           Date().timeIntervalSince(lastObserverRetry) > 5 {
            lastObserverRetry = Date()
            focus.reobserve(pid: apps.pid, bundleID: apps.bundleID)
        }

        // No layout pair means every word is unreadable. Rebuilding it needs a
        // layout change to arrive, and without a working replacement nothing
        // changes the layout — a closed loop only an outside event breaks.
        // Rebuild when it is missing — and also when it has quietly stopped
        // describing reality. A snapshot of the wrong layout is worse than none:
        // a missing one at least says so, while a wrong one reads every word
        // through the wrong table and refuses each of them for what look like
        // good reasons.
        if currentLayouts == nil {
            refreshLayouts()
        } else if let pair = currentLayouts,
                  let now = InputSourceService.currentLayout(),
                  InputSourceService.identifier(of: now) != pair.source.layoutID {
            staleLayoutSnapshots.bump()
            refreshLayouts()
        }

        // A field we could not classify. Ask again — Electron builds its
        // accessibility tree lazily, and the answer unavailable a moment ago is
        // often available now.
        //
        // Not in Chrome and Firefox, though: there the answer is known to be
        // permanently unavailable (00-DECISIONS.md, Н10), and asking every
        // second forever is a cost with no possible return. Not asking a
        // question whose answer cannot exist is the cheapest optimisation there
        // is.
        // And not every second: each attempt is a synchronous round trip into
        // another process, and a first version of this heartbeat asked once a
        // second forever — 41% of a core, which is the failure this project
        // treats as disqualifying. Five seconds is often enough to recover from
        // a missed notification and rare enough to cost nothing.
        if focus.fieldRole == .unknown,
           !apps.bundleID.isEmpty,
           !policies.hidesFieldRoles(apps.bundleID),
           Date().timeIntervalSince(lastUnknownRetry) > 5 {
            lastUnknownRetry = Date()
            focus.refresh(bundleID: apps.bundleID, startsWakeLadder: false)
            publishContext(bundleID: apps.bundleID, appName: apps.appName)
        }

        // A replacement that never finished would block every later one.
        if isReplacing, Date().timeIntervalSince(replacementStartedAt) > 3 {
            isReplacing = false
            note("замена не завершилась — блокировка снята")
        }
    }

    private var replacementStartedAt = Date.distantPast
    private var lastUnknownRetry = Date.distantPast
    private var lastObserverRetry = Date.distantPast
    let blindCarriesRefused = AtomicCounter()
    /// Words dropped because the context did not allow acting.
    let refusedByContext = AtomicCounter()
    /// Times the field answered only when asked again at a word boundary.
    let lateFieldAnswers = AtomicCounter()
    /// Times the layout snapshot was found describing a layout we had left.
    let staleLayoutSnapshots = AtomicCounter()
    /// Words that waited for the field answer and got it.
    let fieldWaitsRewarded = AtomicCounter()
    /// Words that waited and were let go.
    let fieldWaitsAbandoned = AtomicCounter()
    /// Runs that were too long for the field and were retried on one word.
    let shrunkRuns = AtomicCounter()
    private var lastCommitFieldRetry = Date.distantPast
    private var lastClickFieldRetry = Date.distantPast
    /// A tap that would not open. Try again, rather than never.
    ///
    /// `start()` can fail for a moment — the window server busy after a wake,
    /// access revoked and restored, fast user switching — and until now one
    /// such moment was the end of it: the heartbeat above only looks at a tap
    /// that is running, so the application stayed running, visible and deaf
    /// until somebody launched it again. That is the failure CLAUDE.md §8 puts
    /// first: stopped working, silently, and the user cannot tell why.
    private func retryStartAfterFailure() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStartRetry > 30 else { return }
        lastStartRetry = now
        guard tap.start() else {
            menuBar.update(permissions: Permissions.current().looksStuck ? .stuck : .missing)
            return
        }
        tapStartRetriesRewarded.bump()
        tap.setHotkeyStyle(Settings.shared.hotkeyStyle)
        // Whatever was typed while nothing was listening is unknown to us.
        tap.invalidateBuffer(reason: .caretMoved)
        menuBar.update(permissions: .granted)
        note("перехват открылся со второй попытки")
    }

    private var lastStartRetry: TimeInterval = -.infinity
    /// Times a tap that had refused to open opened later.
    let tapStartRetriesRewarded = AtomicCounter()

    private var tapLiveness = TapLiveness()
    /// Times the tap thread was asked to check in because it had gone quiet.
    let tapProbes = AtomicCounter()
    /// Times it did not answer and was replaced.
    let tapRestarts = AtomicCounter()
    private var hasRelaunchedForPermissions = false
    /// Shared with onboarding: both paths can restart the process, and the rule
    /// that stops them looping is only useful if they count the same restarts.
    static let relaunchStampKey = "lastPermissionRelaunch"

    /// Main thread only — it reads TIS.
    private func refreshLayouts() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let current = InputSourceService.currentLayout(),
              let currentTable = keyMapper.table(for: current),
              let sourceLanguage = InputSourceService.primaryLanguage(of: current) else {
            os_unfair_lock_lock(&layoutsLock); layouts = nil; os_unfair_lock_unlock(&layoutsLock)
            return
        }
        // The first *usable* other layout, not simply the first.
        //
        // `enabledKeyboardLayouts` returns everything selectable, including
        // input methods that have no `UnicodeKeyLayoutData` at all. Taking
        // `.first` and giving up if it did not work meant one unusable entry —
        // an input method sorted ahead of the real layout — silently switched
        // the whole app off, with nothing to say why.
        var chosen: (source: TISInputSource, table: KeyMapper.Table, language: String)?
        for candidate in InputSourceService.enabledKeyboardLayouts()
        where InputSourceService.identifier(of: candidate) != currentTable.layoutID {
            guard let language = InputSourceService.primaryLanguage(of: candidate),
                  language != sourceLanguage,
                  let table = keyMapper.table(for: candidate) else { continue }
            chosen = (candidate, table, language)
            break
        }
        guard let chosen else {
            os_unfair_lock_lock(&layoutsLock); layouts = nil; os_unfair_lock_unlock(&layoutsLock)
            return
        }
        let other = chosen.source, otherTable = chosen.table, targetLanguage = chosen.language
        let pair = InputSourceService.LayoutPair(source: currentTable, target: otherTable,
                                                 sourceLanguage: sourceLanguage,
                                                 targetLanguage: targetLanguage,
                                                 targetInputSource: other,
                                                 sourceInputSource: current)
        os_unfair_lock_lock(&layoutsLock)
        if let old = layouts, old.source.layoutID != pair.source.layoutID {
            previousLayouts = old
            previousEpoch = layoutEpoch
            layoutEpoch &+= 1
            currentEpochIsOurs = awaitingOwnSwitch
            awaitingOwnSwitch = false
        }
        layouts = pair
        let epoch = layoutEpoch
        os_unfair_lock_unlock(&layoutsLock)
        // Stamped onto every keystroke from here on.
        tap.layoutEpoch.value = UInt64(epoch)

        // Which keys end a sentence depends on the layout, so it is worked out
        // here and handed to the tap as a bitmap it can read without asking
        // anybody anything.
        tap.setSentencePunctuation(keyMapper.sentencePunctuation(in: currentTable, other: otherTable))
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
        // Either a browser we know keeps its tree closed, or any application
        // that just answered with a web container. The second case is what makes
        // the gesture work in Claude and ChatGPT: the field cannot be identified,
        // so we still never act on our own — but an explicit request from the
        // person sitting there is a signal we cannot get any other way, and
        // refusing it leaves them with nothing.
        replacer.targetPID = focus.observedPID
        hot.fieldRoleUnavailable = policies.hidesFieldRoles(bundleID) || focus.answeredWithWebContainer
        if !Settings.shared.automaticEnabled, hot.policy == .automatic {
            hot.policy = .hotkeyOnly
        }
        context.publish(hot: hot, cold: ColdContext(bundleID: bundleID, appName: appName))
    }

    /// M1–M3 end to end: a word ended, check it is allowed to be touched at all,
    /// then render it in the active layout and in the other one. Deciding which
    /// reading is right is M5; applying the change is M4.
    private func evaluate(_ word: [KeyRecord], terminator: KeyRecord, isRetry: Bool = false) {
        if !isRetry { wordsCommitted.bump() }
        // Captured here, before any hop. Everything downstream compares against it.
        let generation = tap.inputGeneration.value
        guard let reading = read(word) else {
            unreadableWords.bump()
            // We know a word was typed and we do not know what it was. That is
            // the same position as "the caret moved": the chain's description of
            // the text on screen now has a hole in it, and a later replacement
            // measured against it would delete the wrong characters. Fail closed
            // (§2.1.6) — forget the run rather than guess at it.
            chain.clear()
            undo.invalidate()
            // The snapshot is missing or unusable. Ask for it again rather than
            // waiting for a layout change that may never come — that wait is a
            // closed loop, since without a working replacement nothing switches
            // the layout in the first place.
            DispatchQueue.main.async { [weak self] in self?.refreshLayouts() }
            return
        }
        wordsConvertible.bump()

        // The veto runs on the rendered word, before any scoring — it is cheap
        // and it is the layer that keeps us out of trouble.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Ask about the field before judging the word — and on this thread,
            // where asking is allowed.
            //
            // The role of the focused field is answered by another process, and
            // the answer often arrives later than the first word typed after
            // clicking into that field. Until it does, the veto below refuses on
            // `.fieldRole` and the word is dropped without a trace.
            //
            // That is exactly how this was reported: "sometimes it does not
            // fire; I erase the word, type it again, and then it works".
            // Retyping worked not because anything about the word changed, but
            // because erasing and retyping takes a few seconds and the answer
            // turned up in between.
            //
            // A word boundary is a rare enough moment to afford one synchronous
            // question, and it is asked only when we genuinely do not know.
            // Secure input and "leave this application alone" are answers, not
            // gaps, and never come here.
            if context.current.fieldRole == .unknown, !context.current.isSecureInput,
               !apps.bundleID.isEmpty, !policies.hidesFieldRoles(apps.bundleID),
               Date().timeIntervalSince(lastCommitFieldRetry) > 1 {
                lastCommitFieldRetry = Date()
                focus.refresh(bundleID: apps.bundleID, startsWakeLadder: false)
                publishContext(bundleID: apps.bundleID, appName: apps.appName)
                if context.current.fieldRole == .text { lateFieldAnswers.bump() }
            }

            // Punctuation that is also a letter in the other layout is settled
            // first, so everything below judges the word itself: `ghbdtn.` is
            // «привет» and a full stop, `cdj.` is «свою».
            // A word begun in one layout and finished in another is not a word
            // we can judge: half of it means one thing on screen and another
            // in our reading of it.
            if reading.straddlesLayouts {
                repairStraddlingWord(word, reading: reading,
                                     terminator: terminator, generation: generation)
                return
            }

            let settled = ending(of: word, reading)

            // Judged with the context we have just confirmed, not with one read
            // on another queue a moment ago. The veto and the action have to
            // agree about the world; when they were computed at different times
            // they could disagree, and the disagreement was invisible.
            let verdict = VetoGate.evaluate(.init(word: settled.typed,
                                                  context: context.current))

            lastPair = (typed: settled.typed, alternative: settled.alternative)
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
            case .vetoed(.fieldRole):
                // Not a judgement about the word — an absence of information.
                //
                // Every other veto is a decision: this looks like a password,
                // this is a path, this application is off limits. `.fieldRole`
                // only says the application has not told us what the cursor is
                // in yet, and that is a question that answers itself a moment
                // later. Throwing the word away for it is why this kept being
                // reported as unreliable: the answer arrived, just after we had
                // stopped caring.
                //
                // So the word waits instead. Nothing is typed over it — the
                // generation check below proves that — and the text is still on
                // screen, so acting when the answer arrives is as safe as acting
                // now would have been.
                lastVetoReason = .fieldRole
                if isRetry {
                    // Уже ждали и не дождались.
                    wordsVetoed.bump()
                    chain.clear()
                } else {
                    scheduleFieldRetry(word, terminator: terminator,
                                       generation: generation, attempt: 1)
                }
                return
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
            // Only a space is safe to act on.
            //
            // Return has usually already done something irreversible — sent the
            // message, submitted the form — so the characters before the caret
            // are no longer the ones we just watched being typed, and deleting
            // that many would eat somebody else's text. Tab moved focus, which
            // is the same problem. Escape may have closed the field entirely.
            guard let tail = terminatorText(terminator) else {
                chain.clear()
                logDecision("\(settled.typed.count) симв.: закрыто не пробелом — не трогаем")
                return
            }
            // Punctuation found inside the word goes back exactly as typed,
            // in front of whatever ended it.
            let trailing = settled.marks + tail
            // Only a space lets the next word reach back over this one: with
            // punctuation between them they are not a run, they are two
            // sentences' worth of text and rebuilding both is not ours to do.
            if trailing != " " { chain.clear() }
            considerAutomatic(word: word,
                              typed: settled.typed,
                              alternative: settled.alternative,
                              sourceLanguage: reading.sourceLanguage,
                              targetLanguage: reading.targetLanguage,
                              target: reading.target,
                              trailing: trailing,
                              generation: generation)
        }
    }

    /// Puts back together a word that a layout switch cut in half.
    ///
    /// After a correction we switch the system layout so the rest of the phrase
    /// comes out right. That switch is not instant — measured here at 52 ms at
    /// best and 243 ms at worst — and anything typed inside that window still
    /// comes out in the old alphabet. Type on without pausing and the next word
    /// arrives as «как lела»: one letter from before the switch, the rest from
    /// after.
    ///
    /// Nothing noticed this before, because the word reads as «дела» to us —
    /// every key rendered through the layout in force by the end. The screen
    /// said otherwise, so the word looked correct and was left alone.
    ///
    /// The repair is deterministic rather than statistical: the keys are known,
    /// the layout the person ended up in is known, and the only question is
    /// whether the result is a real word. If it is not, nothing happens —
    /// a mixed word nobody can vouch for is left exactly as it is.
    private func repairStraddlingWord(_ word: [KeyRecord], reading: Reading,
                                      terminator: KeyRecord, generation: UInt64) {
        // Whatever the chain believed about this run, there is a seam in it now.
        chain.clear()
        undo.invalidate()
        straddledWords.bump()

        // Which layout did the person mean for the whole word? The dictionary
        // decides between the two readings; see `SeamRepair`.
        let candidates = [
            SeamRepair.Candidate(text: keyMapper.render(word, with: reading.pair.source) ?? "",
                                 language: reading.pair.sourceLanguage),
            SeamRepair.Candidate(text: keyMapper.render(word, with: reading.pair.target) ?? "",
                                 language: reading.pair.targetLanguage),
        ]
        guard let meant = SeamRepair.meant(onScreen: reading.typed, candidates: candidates,
                                           isKnownWord: { [weak self] text, language in
                                               guard let model = self?.modelStore.model(for: language)
                                               else { return false }
                                               return model.contains(LanguageModel.normalized(text))
                                           }) else {
            logDecision("\(reading.typed.count) симв.: шов раскладок, собрать не из чего")
            return
        }
        // Switching the layout afterwards only makes sense when the word turned
        // out to belong to the other one — a name or a brand typed after we had
        // already switched.
        let landing = meant.language == reading.pair.targetLanguage ? reading.pair.targetInputSource : nil
        let intended = meant.text
        guard context.current.allowsAutomaticReplacement else {
            refusedByContext.bump()
            logDecision("\(reading.typed.count) симв.: шов раскладок, контекст запретил")
            return
        }
        guard case .allowed = VetoGate.evaluate(.init(word: intended, context: context.current)) else {
            wordsVetoed.bump()
            logDecision("\(reading.typed.count) симв.: шов раскладок «\(intended.count)» запрещено")
            return
        }
        guard let tail = terminatorText(terminator) else {
            logDecision("\(reading.typed.count) симв.: шов раскладок, закрыто не пробелом")
            return
        }
        straddledWordsRepaired.bump()
        logDecision("\(reading.typed.count) симв.: шов раскладок — собираем слово")
        applyRepair(from: reading.typed + tail, to: intended + tail,
                    switchingTo: landing, generation: generation)
    }

    /// Words typed across a layout switch, and how many of them were put right.
    let straddledWords = AtomicCounter()
    let straddledWordsRepaired = AtomicCounter()

    /// Like `applyRun`, without the layout switch: the layout is already the
    /// one the person is typing in — that is what cut the word in half.
    private func applyRepair(from: String, to: String, switchingTo target: TISInputSource?,
                             generation: UInt64) {
        let bundleID = context.currentCold.bundleID
        guard !isReplacing else { note("пропущено: предыдущая замена ещё идёт"); return }
        isReplacing = true
        replacementStartedAt = Date()
        applyQueue.async { [weak self] in
            guard let self else { return }
            let outcome = replacer.replace(
                original: from, with: to, in: bundleID,
                stillValid: { [weak self] in self?.mayTouchTextNow(generation) == true },
                silence: { [weak self] in self?.tap.secondsSinceLastKeystroke() ?? KeyTapService.longSilence },
                interval: { [weak self] in self?.tap.recentTypingInterval() ?? KeyTapService.slowestAssumedRhythm })
            DispatchQueue.main.async {
                self.isReplacing = false
                guard outcome.succeeded else {
                    self.note(outcome.abandonedLate ? "поздно: текст изменился, не трогаем"
                                                    : "шов раскладок: собрать не удалось")
                    return
                }
                self.replacementsMade.bump()
                self.note("шов раскладок: \(from.count) симв.")
                self.tap.clearBufferAfterReplacement()
                self.undo.arm(original: from, replacement: to, bundleID: bundleID,
                              generation: self.tap.inputGeneration.value)
                // Only when the word turned out to belong to the other layout —
                // a name or a brand typed after we had switched. When it was
                // the layout in force, that is already where the person is.
                if let target, Settings.shared.switchLayoutAfterReplacement {
                    self.noteLayoutRequested()
                    self.inputSources.select(target)
                }
                self.playFeedback()
            }
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
                                   trailing: String?,
                                   generation: UInt64) {
        // Any early exit still has to record the word.
        //
        // The chain is a claim that these words sit next to each other on
        // screen. A word skipped here is still on screen, so leaving it out
        // punches a hole: the next replacement would then reach across it and
        // delete a run that includes text nobody looked at.
        func remember(_ blocked: String) {
            chain.append(.init(typed: typed, alternative: alternative,
                               convertedIsFunctionWord: false, typedIsFunctionWord: false,
                               separator: trailing ?? "", evidence: Scorer.Evidence(),
                               converted: false))
            logDecision(blocked)
        }

        guard !isPaused else { remember("на паузе"); return }
        guard !feedback.isRejected(typed) else {
            remember("\(typed.count) симв.: в списке «не менять»")
            return
        }
        guard let sourceModel = modelStore.model(for: sourceLanguage),
              let targetModel = modelStore.model(for: targetLanguage) else {
            remember("нет модели для \(sourceLanguage)→\(targetLanguage)")
            return
        }

        // The decision itself lives in CorrectionPlanner, which is tested on
        // whole sentences without a keyboard. Keeping a second copy of these
        // rules here would mean the tested logic and the shipped logic drifting
        // apart, and the drift would show up as "it works in the tests".
        let planner = CorrectionPlanner(scorer: Scorer(models: .init(source: sourceModel,
                                                                     target: targetModel)))
        let input = CorrectionPlanner.Input(typed: typed, alternative: alternative,
                                            sourceLanguage: sourceLanguage,
                                            targetLanguage: targetLanguage,
                                            minimumLength: minimumAutomaticLength)
        let (plan, evidence, entry) = planner.plan(input, chain: chain)

        defer { chain.append(entry) }

        // The field was already re-checked before the veto, so by here the
        // context is as good as it is going to get.
        guard context.current.allowsAutomaticReplacement else {
            // Never silently again. A word dropped without a word about it is
            // indistinguishable from a broken application, and this particular
            // silence cost several releases to find.
            refusedByContext.bump()
            remember("\(typed.count) симв.: контекст запретил — поле "
                     + "\(context.current.fieldRole), политика \(context.current.policy)")
            return
        }

        switch plan {
        case .keep, .wait:
            logDecision(String(format: "%d симв.: %@ Λ=%.2f",
                               typed.count, "\(plan)", evidence.perCharacter))
            return
        case .convert(let carryingRequested, let reason):
            // Neighbours are carried on both routes now.
            //
            // They used to be dropped wherever the self-checking route had
            // failed recently, which sounded careful and was not: a single
            // failure — usually nothing worse than macOS capitalising a word —
            // switched off multi-word corrections in that application for a
            // minute. «не это» left «не» behind, «f jnrelf» left the «f», and
            // nothing said why.
            //
            // Safety comes from measuring instead: both routes now check how
            // much text is actually in front of the caret and shrink the run to
            // the current word when it does not fit.
            let carrying = carryingRequested
            let rescued = Array(chain.entries.suffix(carrying))
            var from = typed + (trailing ?? "")
            var to = alternative + (trailing ?? "")
            for item in rescued.reversed() {
                from = item.onScreen + item.separator + from
                to = item.alternative + item.separator + to
            }
            logDecision(String(format: "%d симв.: convert (%@)%@",
                               typed.count, reason.rawValue,
                               carrying > 0 ? ", с ним \(carrying) слева" : ""))
            automaticReplacements.bump()
            if carrying > 0 { chainRescues.bump() }
            // +1 because the current word is appended by the `defer` below, so
            // by the time the replacement finishes the run ends one past here.
            applyRun(from: from, to: to, target: target, marking: carrying + 1,
                     endingAt: chain.recordedCount + 1, generation: generation,
                     soloFallback: carrying > 0
                        ? (typed + (trailing ?? ""), alternative + (trailing ?? ""))
                        : nil)
        }
    }

    /// Replaces a run of already-typed text in one operation.
    ///
    /// One operation rather than several on purpose: separate replacements would
    /// each have to be correct about where the caret is after the previous one,
    /// and the whole point of the chain is that these words sit next to each
    /// other, so the run is a single known string.
    /// - Parameter soloFallback: the same replacement without the carried
    ///   neighbours. Used when the assembled run turns out to be longer than the
    ///   text actually in front of the caret — which happens whenever our
    ///   picture of the earlier words is stale. Replacing the current word alone
    ///   is both safe and what the person was expecting; abandoning everything,
    ///   which is what used to happen, looks exactly like the application not
    ///   working.
    /// Whether it is still safe to rewrite the text we decided about.
    ///
    /// Two questions, and the second one is the one that was missing. The
    /// generation says whether anything has been typed since the decision. The
    /// silence says whether the person has *stopped* — because a replacement is
    /// not instant: it is a run of synthetic events spread over tens of
    /// milliseconds, and a keystroke that lands inside it is deleted by our own
    /// backspaces. Nothing can be checked once that run has started.
    ///
    /// Measured with the self-test typing at a steady rate: at 120 ms between
    /// keystrokes nothing was ever damaged; at 60 and 30 ms, half the two-word
    /// phrases came back broken. Forty milliseconds of quiet is therefore the
    /// price of touching the text at all — and somebody typing faster than that
    /// without pause simply gets no automatic corrections, which is the cheap
    /// kind of mistake (CLAUDE.md §1).
    func mayTouchTextNow(_ generation: UInt64) -> Bool {
        guard tap.inputGeneration.value == generation else {
            lateByTyping.bump()
            return false
        }
        lastQuietMilliseconds = tap.secondsSinceLastKeystroke() * 1000
        return true
    }

    /// How long the system took to actually change the layout after we asked.
    ///
    /// Measured because it decides whether switching is safe at all while
    /// somebody is typing: keystrokes made during this window are produced by
    /// the *old* layout, so a word begun in that window comes out half in one
    /// alphabet and half in the other — «как lела».
    private var layoutRequestedAt: UInt64 = 0
    private(set) var lastLayoutSwitchMilliseconds: Double = -1
    private(set) var worstLayoutSwitchMilliseconds: Double = 0

    func noteLayoutRequested() {
        layoutRequestedAt = mach_absolute_time()
        os_unfair_lock_lock(&layoutsLock)
        awaitingOwnSwitch = true
        os_unfair_lock_unlock(&layoutsLock)
        watchForLayoutToTakeEffect()
    }

    /// Finds out when the layout change we asked for actually happened.
    ///
    /// The system's notification arrives on the main run loop and can be late:
    /// measured here at 52 ms at best and 245 ms at worst. Every keystroke in
    /// between gets stamped with a layout that is no longer in force, which is
    /// worse than not stamping at all — it makes a word look as though it
    /// straddles a change when it does not, and hides the ones that do.
    ///
    /// So for a moment after asking, we look for ourselves. TIS answers from a
    /// local cache and the window is bounded, so this is a few dozen cheap
    /// questions and then silence.
    private func watchForLayoutToTakeEffect() {
        layoutPollUntil = Date().addingTimeInterval(0.5)
        guard layoutPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if let now = InputSourceService.currentLayout(), let pair = currentLayouts,
               InputSourceService.identifier(of: now) != pair.source.layoutID {
                refreshLayouts()
                timer.invalidate()
                layoutPollTimer = nil
                return
            }
            if Date() > layoutPollUntil {
                timer.invalidate()
                layoutPollTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        layoutPollTimer = timer
    }

    private var layoutPollTimer: Timer?
    private var layoutPollUntil = Date.distantPast

    /// Notices a layout change somebody else made, while typing is going on.
    ///
    /// Our own switches are watched above. This is for the other kind: the
    /// person pressing Caps Lock or ⌘-Space themselves. The system's
    /// notification for those arrives on the main run loop and is late often
    /// enough to matter — and every keystroke until it arrives is stamped with
    /// a layout that has already been replaced, which makes a whole word
    /// unreadable to us.
    ///
    /// Only while somebody is typing: at rest this timer asks nothing, which
    /// keeps the promise about doing nothing when nothing is happening.
    private func watchLayoutWhileTyping() {
        guard tap.secondsSinceLastKeystroke() < 3 else { return }
        guard let now = InputSourceService.currentLayout(), let pair = currentLayouts,
              InputSourceService.identifier(of: now) != pair.source.layoutID else { return }
        externalLayoutChanges.bump()
        keyMapper.invalidate()
        refreshLayouts()
    }

    /// Layout changes we did not ask for, caught by looking rather than waiting.
    let externalLayoutChanges = AtomicCounter()

    func noteLayoutArrived() {
        guard layoutRequestedAt != 0 else { return }
        let elapsed = Double(mach_absolute_time() - layoutRequestedAt) * AppDelegate.machToSeconds * 1000
        layoutRequestedAt = 0
        lastLayoutSwitchMilliseconds = elapsed
        worstLayoutSwitchMilliseconds = max(worstLayoutSwitchMilliseconds, elapsed)
    }

    static let machToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Diagnostics: which half of the question said no, and how quiet it was.
    let lateByTyping = AtomicCounter()
    let lateByNoQuiet = AtomicCounter()
    private(set) var lastQuietMilliseconds: Double = -1

    private func applyRun(from: String, to: String, target: TISInputSource,
                          marking count: Int, endingAt boundary: Int, generation: UInt64,
                          soloFallback: (from: String, to: String)? = nil) {
        let bundleID = context.currentCold.bundleID
        guard !isReplacing else { note("пропущено: предыдущая замена ещё идёт"); return }
        replacementStartedAt = Date()
        // Anything typed since the decision moved the caret, and the decision was
        // about characters that are no longer in front of it.
        guard tap.inputGeneration.value == generation else {
            note("пропущено: текст изменился, пока думали")
            return
        }
        isReplacing = true
        applyQueue.async { [weak self] in
            guard let self else { return }
            guard tap.inputGeneration.value == generation else {
                DispatchQueue.main.async { self.isReplacing = false; self.note("пропущено: текст изменился") }
                return
            }
            // Asked again at the last moment, inside the replacer: the checks
            // above happen before a settle delay and up to two accessibility
            // round trips, and a tenth of a second is enough for somebody
            // typing quickly to have put the next letter on screen.
            let stillValid = { [weak self] in self?.mayTouchTextNow(generation) == true }
            let silence = { [weak self] in self?.tap.secondsSinceLastKeystroke() ?? KeyTapService.longSilence }
            let rhythm = { [weak self] in self?.tap.recentTypingInterval() ?? KeyTapService.slowestAssumedRhythm }
            var outcome = replacer.replace(original: from, with: to, in: bundleID,
                                           stillValid: stillValid, silence: silence, interval: rhythm)
            var applied = (from: from, to: to)
            var marked = count
            // Only retry with the shorter run when it demonstrably fits. Without
            // this the fallback was still a guess — and it deleted: «rfr ltkf»
            // came back as «rtkf», five characters gone, because the shorter run
            // did not fit either and nothing checked.
            let fits: Bool = {
                guard let available = outcome.availableBeforeCaret else { return false }
                guard let solo = soloFallback else { return false }
                return (solo.from as NSString).length <= available
            }()
            if !outcome.succeeded, outcome.runDidNotFit, fits, let solo = soloFallback {
                // The run did not fit. Ask for just the word that was actually
                // typed — the neighbours we carried are evidently not where we
                // thought they were.
                self.shrunkRuns.bump()
                outcome = replacer.replace(original: solo.from, with: solo.to, in: bundleID,
                                           stillValid: stillValid, silence: silence, interval: rhythm)
                applied = solo
                marked = 1
            }
            let finalOutcome = outcome, finalApplied = applied, finalMarked = marked
            DispatchQueue.main.async {
                self.isReplacing = false
                guard finalOutcome.succeeded else {
                self.note(finalOutcome.abandonedLate ? "поздно: текст изменился, не трогаем"
                                                     : "замена не удалась")
                return
            }
                let outcome = finalOutcome
                let from = finalApplied.from, to = finalApplied.to
                let count = finalMarked
                self.replacementsMade.bump()
                self.note("\(outcome.strategy.rawValue): \(from.count) → \(to.count) симв.")
                self.chain.markConverted(count: count, endingAt: boundary)
                // The generation after our own synthetic events: our marked
                // events do not bump it, so this is still the user's last real
                // keystroke, and any further typing will move past it.
                self.undo.arm(original: from, replacement: to, bundleID: bundleID,
                              generation: self.tap.inputGeneration.value)
                if Settings.shared.switchLayoutAfterReplacement {
                    self.noteLayoutRequested()
                    self.inputSources.select(target)
                }
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

    private var whatsNewWindow: WhatsNewWindowController?

    /// Diagnostic: whether the notes window is on screen right now.
    var whatsNewIsOpen: Bool { whatsNewWindow?.window?.isVisible ?? false }
    var whatsNewTextVisible: Bool { whatsNewWindow?.notesAreVisible ?? false }

    @objc func showWhatsNew(_ sender: Any?) {
        presentWhatsNew()
    }

    /// - Parameter automatic: true when this is the once-per-version showing
    ///   rather than somebody choosing it from the menu. Only that case is
    ///   allowed to stay silent when there are no notes to show.
    private func presentWhatsNew(automatic: Bool = false) {
        guard let notes = ReleaseNotes.text() else {
            if !automatic { NSSound.beep() }
            return
        }
        // A fresh window each time: the notes are read once, at build time, and
        // keeping a controller alive for something shown a few times a year buys
        // nothing.
        whatsNewWindow?.close()
        whatsNewWindow = WhatsNewWindowController(notes: notes)
        // Order the window in first, then activate. The other way round — which
        // is what the first version did — asks an accessory application to come
        // forward before it has a window to come forward with, and the window
        // ends up behind whatever the person was doing. An update window nobody
        // sees is the same as no update window.
        whatsNewWindow?.showWindow(nil)
        whatsNewWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.showAboutPane()
    }

    /// Waits for the application to say what the cursor is in, then tries again.
    ///
    /// Asks the way the hotkey asks — with the retry ladder — because that is
    /// the difference people kept noticing: "I press the hotkey and then it
    /// starts working". The gesture was not waking anything up; it was simply
    /// the only path that asked properly.
    ///
    /// Bounded on every side: at most two further attempts, roughly two thirds
    /// of a second in total, and abandoned the moment anything at all is typed.
    private func scheduleFieldRetry(_ word: [KeyRecord], terminator: KeyRecord,
                                    generation: UInt64, attempt: Int) {
        guard attempt <= 2 else { fieldWaitsAbandoned.bump(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 1 ? 0.2 : 0.45)) {
            [weak self] in
            guard let self else { return }
            // Anything typed since means the text we were going to replace is no
            // longer the text in front of the caret. Let it go.
            guard tap.inputGeneration.value == generation else { return }
            guard !isPaused, !apps.bundleID.isEmpty,
                  !policies.hidesFieldRoles(apps.bundleID) else { return }

            focus.refresh(bundleID: apps.bundleID)
            publishContext(bundleID: apps.bundleID, appName: apps.appName)

            guard context.current.fieldRole == .text else {
                scheduleFieldRetry(word, terminator: terminator,
                                   generation: generation, attempt: attempt + 1)
                return
            }
            fieldWaitsRewarded.bump()
            evaluate(word, terminator: terminator, isRetry: true)
        }
    }

    /// Renders a run of keystrokes in the active layout and in the other one.
    private struct Reading {
        /// What is on screen — rendered through the layout each key was typed
        /// in, which is only ever more than one when a switch landed mid-word.
        let typed: String
        let alternative: String
        let target: TISInputSource
        let sourceLanguage: String
        let targetLanguage: String
        /// The snapshot it was read with, so that settling the word's ending
        /// later uses the same tables rather than whatever is current by then.
        let pair: InputSourceService.LayoutPair
        /// The word was begun in one layout and finished in another.
        let straddlesLayouts: Bool
    }

    /// Safe from any queue: it reads the cached layout pair and does no TIS calls.
    private func read(_ word: [KeyRecord]) -> Reading? {
        guard let snapshot = layoutSnapshot() else { return nil }
        let pair = snapshot.pair
        guard let alternative = keyMapper.render(word, with: pair.target) else { return nil }

        // The ordinary case: every key was typed in the layout in force now.
        //
        // Or the layout was changed by somebody else, in which case the stamps
        // are not worth reading: we learn about those changes late, so an older
        // stamp on the first key means "we had not heard yet", not "typed in
        // the old alphabet".
        if word.allSatisfy({ $0.layout == snapshot.epoch }) || !snapshot.epochIsOurs {
            guard let typed = keyMapper.render(word, with: pair.source) else { return nil }
            return Reading(typed: typed, alternative: alternative, target: pair.targetInputSource,
                           sourceLanguage: pair.sourceLanguage, targetLanguage: pair.targetLanguage,
                           pair: pair, straddlesLayouts: false)
        }

        // Otherwise a layout change landed inside the word, and the text on
        // screen is part one alphabet, part the other. Read it the way it is:
        // each key through the layout it was actually typed in.
        guard let onScreen = renderAcrossLayouts(word, snapshot: snapshot) else { return nil }
        return Reading(typed: onScreen, alternative: alternative, target: pair.targetInputSource,
                       sourceLanguage: pair.sourceLanguage, targetLanguage: pair.targetLanguage,
                       pair: pair, straddlesLayouts: true)
    }

    /// Renders a word whose keys were typed in two different layouts.
    ///
    /// Only the layout in force and the one before it can be resolved; anything
    /// older is a word we lost track of, and the honest answer there is nothing.
    private func renderAcrossLayouts(_ word: [KeyRecord], snapshot: LayoutSnapshot) -> String? {
        var text = ""
        for key in word {
            let table: KeyMapper.Table
            if key.layout == snapshot.epoch {
                table = snapshot.pair.source
            } else if key.layout == snapshot.previousEpoch, let previous = snapshot.previous {
                table = previous.source
            } else {
                return nil
            }
            guard let rendered = keyMapper.render([key], with: table) else { return nil }
            text += rendered
        }
        return text
    }

    /// The word without punctuation that only looks like part of it.
    ///
    /// On the Latin layout a full stop, a comma or a semicolon is also a
    /// Cyrillic letter, so the key buffer keeps them inside the word and this
    /// decides, with the dictionaries, which they were (`WordEnding`).
    private func ending(of keys: [KeyRecord], _ reading: Reading) -> WordEnding.Reading {
        let pair = reading.pair
        let scorer = modelStore.model(for: pair.sourceLanguage).flatMap { source in
            modelStore.model(for: pair.targetLanguage).map { target in
                Scorer(models: .init(source: source, target: target))
            }
        }
        return WordEnding.resolve(keys, mapper: keyMapper, source: pair.source,
                                  target: pair.target, scorer: scorer)
            ?? WordEnding.Reading(typed: reading.typed, alternative: reading.alternative, marks: "")
    }

    // MARK: - Hotkey

    private func handle(hotkey event: HotkeyDetector.Event) {
        switch event {
        case .panicToggle:
            isPaused.toggle()
            // Drop everything held: after a pause the caret is wherever the user
            // took it, and resuming must not act on a stale picture of the text.
            chain.clear()
            undo.invalidate()
            tap.invalidateBuffer(reason: .appChanged)
            menuBar.update(paused: isPaused)
            note(isPaused ? "пауза" : "работаем")
            NSSound.beep()
        case .doubleTapShift:
            // Undo first: pressing the hotkey right after a replacement means
            // "that was wrong", not "do it again".
            guard !isPaused else {
                // Say something. A paused application answering the hotkey with
                // perfect silence is indistinguishable from a broken one, and
                // that is how it was reported: "it stops working after a while,
                // and the hotkey does nothing either". Pausing is only ever
                // visible in the menu bar, which is exactly what people miss.
                note("на паузе — оба Shift вместе, чтобы продолжить")
                menuBar.explainPause()
                NSSound.beep()
                return
            }
            // Ask about the field first of all.
            //
            // This used to happen further down, and moving the selection check
            // above it was a mistake: the selection path returns without ever
            // reaching the refresh, so the first press landed on a field we did
            // not know yet and was refused. The second press worked because the
            // periodic check had answered in between — "it fires on the second
            // press", exactly as reported.
            if focus.fieldRole == .unknown, !apps.bundleID.isEmpty {
                focus.refresh(bundleID: apps.bundleID)
                publishContext(bundleID: apps.bundleID, appName: apps.appName)
            }

            // A selection comes first, before the undo.
            //
            // Highlighting text and pressing the hotkey is an instruction about
            // *that* text, and it cannot mean "undo what you did a moment ago" —
            // somebody who wants the previous correction back does not select
            // something else first. Checking undo first meant that fixing two
            // phrases in a row undid the first one instead of converting the
            // second, which is what "it only works a few times" was.
            if let selection = TextSelection.current(pid: focus.observedPID),
               !selection.text.isEmpty {
                logDecision("жест: выделение \(selection.text.count) симв.")
                convertSelection(selection)
                return
            }
            if undo.isAvailable, let pending = undo.consume(currentGeneration: tap.inputGeneration.value) {
                logDecision("жест: откат")
                revert(pending)
                return
            }
            logDecision("жест: слово")
            convertOnHotkey()
        }
    }

    /// What the hotkey acts on, in priority order.
    ///
    /// Selection first: if the user went to the trouble of selecting text, that
    /// is unambiguously what they mean, and it is the only way to fix a whole
    /// sentence typed in the wrong layout.
    private func convertOnHotkey() {
        if let selection = TextSelection.current(pid: focus.observedPID), !selection.text.isEmpty {
            convertSelection(selection)
            return
        }
        tap.requestHotkeyTarget { [weak self] target in
            guard let self else { return }
            if !target.inProgress.isEmpty {
                logDecision("жест: слово в наборе, \(target.inProgress.count) клавиш")
                apply(keys: target.inProgress, trailing: nil)
            } else if let committed = target.justCommitted,
                      let terminator = terminatorText(committed.terminator) {
                // Reachable only while nothing at all has happened since the
                // space — the buffer guarantees that, not a stopwatch.
                apply(keys: committed.keys, trailing: terminator)
            } else {
                logDecision("жест: нечего исправлять")
                note("нечего исправлять")
                NSSound.beep()
            }
        }
    }

    /// What the key that finished the word put on screen, if we can retype it.
    ///
    /// A space, or punctuation — a full stop, a comma, a question mark. Those
    /// are characters like any other and can be written back verbatim.
    ///
    /// Tab and Return cannot: they would have to be re-sent as keys, and in most
    /// applications Return has already done something irreversible — sent the
    /// message, submitted the form — so the characters before the caret are no
    /// longer the ones we watched being typed.
    ///
    /// The punctuation is rendered through the layout that produced it and put
    /// back **unchanged**. Somebody who typed a question mark meant a question
    /// mark; the same physical key gives `&` in the other alphabet, and
    /// converting it would be a different kind of wrong.
    private func terminatorText(_ record: KeyRecord) -> String? {
        if record.keyCode == Self.spaceKeyCode { return " " }
        guard let pair = currentLayouts,
              let rendered = keyMapper.render([record], with: pair.source),
              rendered.count == 1, let character = rendered.first,
              KeyMapper.sentenceMarks.contains(character)
        else { return nil }
        return rendered
    }

    /// Converts a whole selection, however long, in one go.
    ///
    /// This is the answer to "I wrote a paragraph in the wrong layout". It reads
    /// the selection back into keystrokes, renders them in the other layout and
    /// writes the result over the selection — so spaces, punctuation and case all
    /// come out where they were.
    private func convertSelection(_ selection: TextSelection.Snapshot) {
        guard let pair = currentLayouts else {
            note("не удалось прочитать раскладку"); NSSound.beep(); return
        }
        let currentTable = pair.source, otherTable = pair.target, other = pair.targetInputSource

        // Read the text back into the keys that would have produced it, then ask
        // what those keys mean in the other layout.
        // Which way to convert is read from the text, not from the keyboard.
        //
        // This was the bug that made selections "almost never work". The whole
        // point of selecting text is that it is in the *wrong* alphabet, and by
        // the time somebody notices, the keyboard has usually been switched back
        // to the right one. Converting "out of the currently active layout" then
        // asks the English table to explain the Cyrillic letters in «руддщ»,
        // finds nothing it recognises, and refuses with a beep.
        //
        // So both directions are tried and the one that actually explains the
        // text wins. Neither explaining it means there is genuinely nothing to
        // do here.
        //
        // Character by character, leaving alone what no layout can express — an
        // em dash, an ellipsis, an emoji, a line break. For a word we watched
        // being typed that strictness is right; for a sentence highlighted by
        // hand it is just a refusal.
        let (converted, mapped, useForward) =
            keyMapper.convertEitherWay(selection.text, first: currentTable, second: otherTable)
        // Where the keyboard should end up: after fixing text that was typed in
        // the other layout, the layout to carry on in is that text's own.
        let landing = useForward ? pair.targetInputSource : pair.sourceInputSource

        guard mapped > 0, converted != selection.text else {
            note("в выделении нечего менять")
            NSSound.beep()
            return
        }

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
                self.note("выделение: \(selection.text.count) симв.")
                self.tap.clearBufferAfterReplacement()
                self.undo.arm(original: selection.text, replacement: converted,
                              bundleID: bundleID, generation: self.tap.inputGeneration.value)
                if Settings.shared.switchLayoutAfterReplacement {
                    self.noteLayoutRequested()
                    self.inputSources.select(landing)
                }
                self.playFeedback()
            }
        }
    }

    private static let spaceKeyCode: UInt16 = 0x31

    private func apply(keys: [KeyRecord], trailing: String?,
                       explicit: Bool = true,
                       precomputed: (typed: String, alternative: String, target: TISInputSource)? = nil) {
        let resolved: (typed: String, alternative: String, target: TISInputSource)
        // Punctuation that turned out to be punctuation, not a letter of the
        // other alphabet: kept as typed, between the word and its terminator.
        var marks = ""
        if let precomputed {
            resolved = precomputed
        } else if let wordReading = read(keys) {
            let settled = ending(of: keys, wordReading)
            resolved = (settled.typed, settled.alternative, wordReading.target)
            marks = settled.marks
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
            logDecision("жест: запрещено (\(reason.rawValue))")
            note("запрещено: \(reason.rawValue)")
            NSSound.beep()
            return
        }

        let bundleID = context.currentCold.bundleID
        let from = reading.typed + marks + (trailing ?? "")
        let to = reading.alternative + marks + (trailing ?? "")
        logDecision("жест: меняем \(from.count)→\(to.count)")

        guard !isReplacing else { note("пропущено: предыдущая замена ещё идёт"); return }
        isReplacing = true
        replacementStartedAt = Date()
        let generation = tap.inputGeneration.value

        // Off the main thread: synthetic typing sleeps between events, and a
        // ten-letter word is over a hundred milliseconds of it.
        applyQueue.async { [weak self] in
            guard let self else { return }
            let outcome = replacer.replace(
                original: from, with: to, in: bundleID,
                stillValid: { [weak self] in self?.mayTouchTextNow(generation) == true },
                silence: { [weak self] in self?.tap.secondsSinceLastKeystroke() ?? KeyTapService.longSilence },
                interval: { [weak self] in self?.tap.recentTypingInterval() ?? KeyTapService.slowestAssumedRhythm })
            DispatchQueue.main.async {
                self.isReplacing = false
                guard outcome.succeeded else {
                    self.note(outcome.abandonedLate ? "поздно: текст изменился, не трогаем"
                                                    : "замена не удалась")
                    return
                }
                self.replacementsMade.bump()
                self.note("\(outcome.strategy.rawValue): \(reading.typed.count) симв.")
                self.tap.clearBufferAfterReplacement()
                // The generation after our own synthetic events: our marked
                // events do not bump it, so this is still the user's last real
                // keystroke, and any further typing will move past it.
                self.undo.arm(original: from, replacement: to, bundleID: bundleID,
                              generation: self.tap.inputGeneration.value)
                // Switch the layout too, or the next word comes out wrong again
                // and the correction was pointless.
                if Settings.shared.switchLayoutAfterReplacement {
                    self.noteLayoutRequested()
                    self.inputSources.select(reading.target)
                }
                self.playFeedback()
            }
        }
    }

    private func revert(_ pending: UndoController.Pending) {
        guard !isReplacing else { NSSound.beep(); return }
        // Same check as `applyRun`, and for the same reason: between deciding to
        // revert and actually posting backspaces the user may type, and the
        // characters in front of the caret stop being the ones we put there.
        guard tap.inputGeneration.value == pending.generation else {
            note("откат отменён: текст изменился")
            NSSound.beep()
            return
        }
        isReplacing = true
        applyQueue.async { [weak self] in
            guard let self else { return }
            let outcome = replacer.replace(
                original: pending.replacement, with: pending.original, in: pending.bundleID,
                stillValid: { [weak self] in
                    self?.tap.inputGeneration.value == pending.generation
                },
                silence: { [weak self] in self?.tap.secondsSinceLastKeystroke() ?? KeyTapService.longSilence },
                interval: { [weak self] in self?.tap.recentTypingInterval() ?? KeyTapService.slowestAssumedRhythm })
            DispatchQueue.main.async {
                self.isReplacing = false
                guard outcome.succeeded else { self.note("откат не удался"); return }
                self.undosMade.bump()
                // The word the user just rejected. Trimmed of the separator we
                // added, so "ghbdtn " and "ghbdtn" are the same word.
                // The word to remember is the one the user *typed*, because that
                // is what will be seen again next time. Storing the converted
                // form meant the list was consulted with «ghbdtn» and filled
                // with «привет» — two different keys, so nothing was ever found
                // and undoing taught the app nothing at all.
                let word = pending.original.trimmingCharacters(in: .whitespacesAndNewlines)
                let becamePermanent = self.feedback.recordUndo(of: word)
                self.note(becamePermanent
                          ? "откат \(pending.original.count) симв.; слово занесено в «не менять» навсегда"
                          : "откат \(pending.original.count) симв.")
                self.tap.clearBufferAfterReplacement()
                NSSound(named: "Pop")?.play()
            }
        }
    }

    #if DEBUG
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

    /// Drives the hotkey path from the self-test, without synthesising
    /// modifiers — the detector is exercised by its own unit tests.
    func triggerHotkeyForSelfTest() {
        handle(hotkey: .doubleTapShift)
    }

    func readingForSelfTest(keys: [KeyRecord]) -> (typed: String, alternative: String)? {
        guard let reading = read(keys) else { return nil }
        return (reading.typed, reading.alternative)
    }
    #endif

    private func note(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.lastReplacementNote = text }
    }

    @objc func showDiagnostics(_ sender: Any?) {
        #if DEBUG
        if diagnostics == nil {
            diagnostics = DiagnosticsWindowController(tap: tap, secureInput: secureInput)
        }
        NSApp.activate(ignoringOtherApps: true)
        diagnostics?.showWindow(nil)
        #endif
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
