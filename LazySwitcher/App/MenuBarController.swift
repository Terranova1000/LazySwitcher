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
        case .missing: return "Нет доступа к Универсальному доступу"
        case .stuck:   return "Доступ «залип» — нужен сброс"
        case .granted: break
        }
        if secureInputActive {
            if let who = SecureInputMonitor.likelyResponsibleProcess() {
                return "Приостановлено: похоже, ввод перехватил «\(who.name)»"
            }
            return "Приостановлено: ввод защищён системой"
        }
        return "M0 — разведка боем"
    }

    private enum MenuTag: Int { case status = 1 }

    private func buildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.tag = MenuTag.status.rawValue
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let diag = NSMenuItem(title: "Диагностика…", action: #selector(AppDelegate.showDiagnostics(_:)), keyEquivalent: "d")
        diag.target = target
        menu.addItem(diag)

        let settings = NSMenuItem(title: "Открыть Универсальный доступ…",
                                  action: #selector(AppDelegate.openAccessibilitySettings(_:)), keyEquivalent: "")
        settings.target = target
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(AppDelegate.quit(_:)), keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)

        item.menu = menu
    }
}
