import AppKit

/// The status item and its menu.
///
/// Holds a strong reference to `NSStatusItem` on purpose: let it go and the icon
/// silently vanishes, which is a genuinely confusing bug to chase.
final class MenuBarController {

    enum PermissionState { case granted, missing, stuck }

    private let item: NSStatusItem
    private weak var target: AppDelegate?
    private var permissions: PermissionState = .missing
    private var secureInputActive = false

    init(delegate: AppDelegate) {
        target = delegate
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        redraw()
    }

    func update(permissions state: PermissionState) {
        permissions = state
        redraw()
    }

    func update(secureInput active: Bool) {
        secureInputActive = active
        redraw()
    }

    /// A newer version exists. Shown as a menu entry rather than a notification:
    /// a background agent that pops an alert to say hello is a nuisance.
    func showUpdateAvailable(version: String) {
        guard let menu = item.menu else { return }
        let title = L("menu.update.available", version)
        if menu.items.contains(where: { $0.title == title }) { return }
        let entry = NSMenuItem(title: title, action: #selector(AppDelegate.openReleasesPage(_:)),
                               keyEquivalent: "")
        entry.target = target
        menu.insertItem(entry, at: 1)
        menu.insertItem(.separator(), at: 2)
    }

    /// Blinks the icon after a correction. The cheapest possible acknowledgement
    /// that something changed, and it works with the sound turned off.
    func flash() {
        item.button?.alphaValue = 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.item.button?.alphaValue = 1.0
        }
    }

    private func redraw() {
        let symbol: String
        switch (permissions, secureInputActive) {
        case (.missing, _), (.stuck, _): symbol = "exclamationmark.triangle"
        case (_, true):                  symbol = "lock.fill"
        case (_, false):                 symbol = "character.cursor.ibeam"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lazy Switcher")
        image?.isTemplate = true
        item.button?.image = image
        item.menu?.item(withTag: MenuTag.status.rawValue)?.title = statusLine
    }

    private var statusLine: String {
        switch permissions {
        case .missing: return L("menu.status.noAccess")
        case .stuck:   return L("menu.status.stuck")
        case .granted: break
        }
        // No name here on purpose: the API that would supply it does not work on
        // macOS 15 (00-DECISIONS.md, Н13), and a name taken from a guess is
        // worse than no name.
        if secureInputActive { return L("menu.status.pausedSecureInput") }
        return L("menu.status.active")
    }

    private enum MenuTag: Int { case status = 1 }

    private func buildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.tag = MenuTag.status.rawValue
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let diag = NSMenuItem(title: L("menu.diagnostics"), action: #selector(AppDelegate.showDiagnostics(_:)), keyEquivalent: "d")
        diag.target = target
        menu.addItem(diag)

        let preferences = NSMenuItem(title: L("menu.settings"),
                                     action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        preferences.target = target
        menu.addItem(preferences)

        let access = NSMenuItem(title: L("menu.accessibility"),
                                action: #selector(AppDelegate.openAccessibilitySettings(_:)), keyEquivalent: "")
        access.target = target
        menu.addItem(access)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(AppDelegate.quit(_:)), keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)

        item.menu = menu
    }
}
