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
        if let front = NSWorkspace.shared.frontmostApplication { adopt(front) }
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
