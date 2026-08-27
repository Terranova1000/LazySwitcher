import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    let tap = KeyTapService()
    let secureInput = SecureInputMonitor()
    let mouse = MouseMonitor()
    let inputSources = InputSourceService()
    let keyMapper = KeyMapper()

    /// Words seen since launch, and how many we could render in both layouts.
    /// Counts only — the words themselves never leave memory.
    let wordsCommitted = AtomicCounter()
    let wordsConvertible = AtomicCounter()
    /// Last word in both readings, for the diagnostics window on screen only.
    private(set) var lastPair: (typed: String, alternative: String)?
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
            if enabled { tap.wipeVolatileState() }
            menuBar.update(secureInput: enabled)
        }
        secureInput.start()
        tap.secureInputMirror.value = secureInput.isEnabled ? 1 : 0

        // A click can put the caret anywhere; keeping the buffer across one
        // would make our backspaces delete somebody else's text.
        mouse.onClick = { [weak self] in self?.tap.invalidateBuffer(reason: .mouseClick) }
        mouse.start()

        inputSources.onLayoutChanged = { [weak self] in self?.keyMapper.invalidate() }
        inputSources.startWatching()

        tap.onWordCommitted = { [weak self] word in self?.evaluate(word) }
        tap.onHotkey = { [weak self] event in self?.handle(hotkey: event) }

        startTapOrExplain()
        showDiagnostics(nil)   // M0: the diagnostics window is the whole product

        // M0 scaffolding — remove at M1.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            M0Report.write(tap: tap, secureInput: secureInput)
        }
        RunLoop.main.add(t, forMode: .common)
        reportTimer = t
        M0Report.write(tap: tap, secureInput: secureInput)
        M0TimeoutSweep.watchForTrigger(tap: tap)
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

    /// M1+M2 end to end: a word ended, render it in the active layout and in the
    /// other one. Deciding which is right is M5; this only proves the chain runs.
    private func evaluate(_ word: [KeyRecord]) {
        wordsCommitted.bump()
        guard let current = InputSourceService.currentLayout(),
              let currentTable = keyMapper.table(for: current) else { return }

        let others = InputSourceService.enabledKeyboardLayouts().filter {
            InputSourceService.identifier(of: $0) != currentTable.layoutID
        }
        guard let other = others.first,
              let otherTable = keyMapper.table(for: other),
              let typed = keyMapper.render(word, with: currentTable),
              let alternative = keyMapper.render(word, with: otherTable)
        else { return }

        wordsConvertible.bump()
        DispatchQueue.main.async { [weak self] in
            self?.lastPair = (typed: typed, alternative: alternative)
        }
    }

    private func handle(hotkey event: HotkeyDetector.Event) {
        switch event {
        case .doubleTapShift: NSSound.beep()          // M6 wires the real action
        case .panicToggle:    NSSound.beep()
        }
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
