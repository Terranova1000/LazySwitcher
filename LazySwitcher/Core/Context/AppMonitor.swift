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

    /// Who is actually in front, which is not the question `frontmostApplication`
    /// answers.
    ///
    /// Measured on macOS 15: after the screen has been locked and unlocked,
    /// `NSWorkspace.shared.frontmostApplication` keeps returning
    /// `com.apple.loginwindow` indefinitely, while `menuBarOwningApplication`
    /// returns the real application. Both were read in the same instant:
    ///
    ///     frontmostApplication:     com.apple.loginwindow (loginwindow)
    ///     menuBarOwningApplication: com.anthropic.claudefordesktop (Claude)
    ///
    /// This is the bug behind "it does not work at first, then it starts".
    /// Locking the screen is something people do many times a day; afterwards we
    /// believed we were in `loginwindow`, refused everything, and only recovered
    /// when an activation notification arrived — which requires switching
    /// applications, because returning to the one already in front is not a
    /// change and produces no notification.
    static func trueFrontmost() -> NSRunningApplication? {
        NSWorkspace.shared.menuBarOwningApplication ?? NSWorkspace.shared.frontmostApplication
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
