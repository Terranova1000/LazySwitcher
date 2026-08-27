import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    let tap = KeyTapService()
    let secureInput = SecureInputMonitor()
    private var menuBar: MenuBarController!
    private var diagnostics: DiagnosticsWindowController?
    private var reportTimer: Timer?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
