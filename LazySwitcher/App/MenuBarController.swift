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
    private var paused = false
    private var updateVersion: String?

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

    func update(paused active: Bool) {
        paused = active
        redraw()
    }

    /// A newer version exists. Shown as a menu entry rather than a notification:
    /// a background agent that pops an alert to say hello is a nuisance.
    /// A new version exists.
    ///
    /// Three signals, deliberately quiet ones. A background agent that throws a
    /// window in front of somebody to announce an optional upgrade has misjudged
    /// its own importance; a dot they will notice next time they look at the
    /// menu bar has not.
    func showUpdateAvailable(version: String) {
        updateVersion = version
        redraw()
        guard let menu = item.menu else { return }
        let title = L("menu.update.available", version)
        if menu.items.contains(where: { $0.title == title }) { return }
        let entry = NSMenuItem(title: title, action: #selector(AppDelegate.showAbout(_:)),
                               keyEquivalent: "")
        entry.target = target
        // A filled dot next to it, so the menu reads as "something new" at a
        // glance rather than only on reading.
        entry.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        menu.insertItem(entry, at: 1)
        menu.insertItem(.separator(), at: 2)
    }

    /// Draws a small dot in the corner of the icon.
    ///
    /// Template images are single-colour, so the badge cannot be a different
    /// colour — it is a dot with a gap punched around it, which reads as
    /// separate from the drawing at any size and inverts with the menu bar like
    /// everything else.
    private static func badged(_ base: NSImage) -> NSImage {
        let size = base.size
        let result = NSImage(size: size)
        result.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        let radius = size.width * 0.22
        let centre = NSPoint(x: size.width - radius * 0.85, y: size.height - radius * 0.85)
        // Gap first, then the dot inside it.
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: centre.x - radius * 1.5, y: centre.y - radius * 1.5,
                                    width: radius * 3, height: radius * 3)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
        result.unlockFocus()
        result.isTemplate = true
        return result
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
        let symbol: String?
        // Our own sloth for the working state, system symbols for everything
        // that needs attention. A warning triangle and a padlock are understood
        // at a glance by everybody; a custom glyph for "something is wrong"
        // would have to be learned first, and the moment it matters is the worst
        // moment to be learning it.
        switch (permissions, secureInputActive, paused) {
        case (.missing, _, _), (.stuck, _, _): symbol = "exclamationmark.triangle"
        case (_, true, _):                     symbol = "lock.fill"
        case (_, _, true):                     symbol = "pause.circle"
        default:                               symbol = nil          // ленивец
        }
        let image: NSImage?
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lazy Switcher")
        } else {
            // Sized explicitly: a status item does not scale its image, and the
            // vector arrives at whatever size the PDF was drawn at.
            let sloth = NSImage(named: "MenuBarIcon")
            sloth?.size = NSSize(width: 18, height: 18)
            image = sloth
        }
        image?.isTemplate = true
        item.button?.image = updateVersion == nil ? image : image.map(Self.badged)
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
        if paused { return L("menu.status.paused") }
        if let updateVersion { return L("menu.status.updateAvailable", updateVersion) }
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

        #if DEBUG
        let diag = NSMenuItem(title: L("menu.diagnostics"),
                              action: #selector(AppDelegate.showDiagnostics(_:)), keyEquivalent: "d")
        diag.target = target
        menu.addItem(diag)
        #endif

        let preferences = NSMenuItem(title: L("menu.settings"),
                                     action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        preferences.target = target
        menu.addItem(preferences)

        let about = NSMenuItem(title: L("menu.about"),
                               action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        about.target = target
        menu.addItem(about)

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
