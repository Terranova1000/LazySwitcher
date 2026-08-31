import AppKit

/// Follows the frontmost application.
///
/// Every app switch invalidates two things: the focused element we were watching
/// (it belonged to the old process) and the word buffer (the caret is somewhere
/// else entirely now).
final class AppMonitor {

    private(set) var bundleID: String = ""
    private(set) var appName: String = ""
    private(set) var pid: pid_t = 0

    var onAppChanged: ((pid_t, String, String) -> Void)?

    /// Diagnostic: how many activation notifications actually arrived.
    private(set) var activationsSeen = 0
    private var token: NSObjectProtocol?

    func start() {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.activationsSeen += 1
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.adopt(app)
        }
        if let front = Self.trueFrontmost() { adopt(front) }
    }

    /// Applications that answer "who is in front" with themselves while the
    /// screen is locked, long after it has been unlocked.
    ///
    /// `com.apple.loginwindow` is the one measured (Н34); `SecurityAgent` is the
    /// same machinery for authentication sheets and is listed for the same
    /// reason, not because it was seen misbehaving.
    private static let lockScreenImposters: Set<String> = [
        "com.apple.loginwindow", "com.apple.SecurityAgent",
    ]

    /// Who is actually in front.
    ///
    /// `frontmostApplication` is the right answer almost always, because it names
    /// the process that keyboard events are being delivered to — which is the
    /// only thing we care about. It has exactly one measured failure: after the
    /// screen has been locked and unlocked it keeps naming `loginwindow`
    /// indefinitely, while `menuBarOwningApplication` names the real application
    /// (Н34). Both read in the same instant:
    ///
    ///     frontmostApplication:     com.apple.loginwindow (loginwindow)
    ///     menuBarOwningApplication: com.anthropic.claudefordesktop (Claude)
    ///
    /// So the substitution is made only for that lie, and never as a general
    /// rule. Version 1.9 made it the general rule and that was wrong: an
    /// accessory application (`LSUIElement`) holding keyboard focus does not own
    /// the menu bar, so `menuBarOwningApplication` names the application *behind*
    /// it. Measured with a purpose-built accessory bundle on macOS 15:
    ///
    ///     frontmost=com.verify.accprobe   menuBar=com.apple.Safari
    ///
    /// — held for as long as the accessory kept focus. Spotlight, Raycast,
    /// Alfred, a password manager's popover and this application's own settings
    /// window are all accessory windows, so the general rule pointed every
    /// decision, every read and every write at whatever happened to be behind
    /// the panel the person was typing into.
    static func trueFrontmost() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        guard shouldBelieveMenuBarOwner(frontmostBundleID: front?.bundleIdentifier) else {
            return front
        }
        return NSWorkspace.shared.menuBarOwningApplication ?? front
    }

    /// The whole rule, as a decision over one value, so it can be tested.
    ///
    /// True only when `frontmostApplication` gave us an answer we know to be a
    /// lie. Any other answer — including one from an accessory application that
    /// does not own the menu bar — is believed, because keyboard events go where
    /// `frontmostApplication` says they go.
    static func shouldBelieveMenuBarOwner(frontmostBundleID: String?) -> Bool {
        guard let id = frontmostBundleID, !id.isEmpty else { return true }
        return lockScreenImposters.contains(id)
    }

    /// Re-reads who is in front and adopts them if we were wrong.
    ///
    /// Cheap — both properties are answered from the workspace's own bookkeeping,
    /// with no round trip into another process — so this is safe to call from a
    /// timer. `adopt` ignores an application we already know about, so being
    /// right costs nothing.
    func resync() {
        if let front = Self.trueFrontmost() { adopt(front) }
    }

    func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }

    private func adopt(_ app: NSRunningApplication) {
        let id = app.bundleIdentifier ?? ""
        guard id != bundleID || app.processIdentifier != pid else { return }
        bundleID = id
        appName = app.localizedName ?? id
        pid = app.processIdentifier
        onAppChanged?(pid, id, appName)
    }
}
