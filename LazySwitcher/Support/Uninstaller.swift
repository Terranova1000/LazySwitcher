import AppKit
import ServiceManagement

/// Removes everything the app has left outside its own bundle.
///
/// Dragging an app to the Trash does **not** remove its settings — macOS keeps
/// preferences and support files exactly where they were, and reinstalling later
/// silently picks them back up. For most apps that is a few kilobytes nobody
/// notices. Here it matters more: the leftovers include the list of words the
/// user taught the app to leave alone and the per-app policies, which is the
/// sort of thing somebody uninstalling would reasonably expect to be gone.
///
/// What this cannot do is remove the Accessibility grant — TCC belongs to the
/// system and no application may edit it. macOS drops it on its own once the
/// bundle is gone, so the honest instruction is "settings removed; now drag the
/// app to the Trash".
enum Uninstaller {

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lazy Switcher")
    }

    /// Everything we might have written, for the confirmation dialog to name.
    static func leftovers() -> [URL] {
        var found: [URL] = []
        if FileManager.default.fileExists(atPath: supportDirectory.path) {
            found.append(supportDirectory)
        }
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences")
            .appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "com.lazyswitcher.app").plist")
        if FileManager.default.fileExists(atPath: preferences.path) { found.append(preferences) }
        return found
    }

    /// Unregisters, wipes, and reports what could not be removed.
    @discardableResult
    static func removeEverything() -> [String] {
        var problems: [String] = []

        // Login item first: leaving a registration behind for a bundle that is
        // about to be deleted is how "ghost" login items happen.
        if SMAppService.mainApp.status != .notRegistered {
            do { try SMAppService.mainApp.unregister() }
            catch { problems.append("объект входа: \(error.localizedDescription)") }
        }

        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }

        for url in leftovers() {
            do { try FileManager.default.removeItem(at: url) }
            catch { problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return problems
    }

    /// Opens the Applications folder with the bundle selected, so the last step
    /// is one drag rather than a hunt.
    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
