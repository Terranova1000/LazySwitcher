import AppKit
import ServiceManagement

/// Registering the app to start at login.
///
/// The state is **read from the system, never from our own settings.** The user
/// can remove the app from Login Items in System Settings at any moment, and a
/// checkbox that keeps claiming "on" after they did is worse than no checkbox:
/// they turn it off and on again, nothing changes, and they conclude the app is
/// broken.
///
/// `SMLoginItemSetEnabled` has been deprecated since macOS 13 and hand-written
/// plists in ~/Library/LaunchAgents are legacy. For a single bundle the current
/// call is `SMAppService.mainApp`.
enum LaunchAtLogin {

    enum State {
        case enabled
        case disabled
        /// Registered, but macOS wants the user to confirm in System Settings.
        /// Has to be shown as its own thing: it looks like failure and is not.
        case requiresApproval
        case unavailable(String)

        var isOn: Bool {
            switch self {
            case .enabled, .requiresApproval: return true
            case .disabled, .unavailable: return false
            }
        }
    }

    static var current: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable("приложение не найдено системой")
        @unknown default: return .unavailable("неизвестное состояние")
        }
    }

    /// Registration only sticks reliably for an app living in /Applications —
    /// which is the same place TCC needs it to be for permissions to survive
    /// updates, so the two requirements agree.
    static var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Result<State, Error> {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return .success(current) }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status != .notRegistered else { return .success(current) }
                try SMAppService.mainApp.unregister()
            }
            return .success(current)
        } catch {
            return .failure(error)
        }
    }

    static func openLoginItemsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
