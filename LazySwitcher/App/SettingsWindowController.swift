import AppKit

/// Settings, in the shape macOS itself uses: a toolbar of panes, one screen of
/// content each, labels in a right-aligned column.
///
/// Two rules held throughout, both learned from the first version:
///
/// **No bare `NSBox()` as a separator.** A default-initialised box is not a rule
/// — it is a titled box, and its default title localises to «Название». That is
/// where the stray captions and the strip under them came from.
///
/// **A hint is one line or it is not there.** The first version explained the
/// measurement behind every setting, which is the right content for the docs and
/// the wrong content for a window somebody opened to change the sound.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    private weak var app: AppDelegate?
    private let settings = Settings.shared

    private enum Pane: String, CaseIterable {
        case general, keys, sound, apps, about

        var title: String { L("settings.tab.\(rawValue)") }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .keys:    return "keyboard"
            case .sound:   return "speaker.wave.2"
            case .apps:    return "app.badge"
            case .about:   return "info.circle"
            }
        }
    }

    private var panes: [Pane: NSView] = [:]
    private var current: Pane = .general
    private let container = NSView()

    // Controls that need refreshing when the world changes underneath them.
    private var launchCheckbox: NSButton!
    private var launchHint: NSTextField!
    private var hotkeyHint: NSTextField!
    private var updateStatus: NSTextField!
    private var appRows: [AppRow] = []
    private var appTable: NSTableView!
    private var showProtected = false

    private struct AppRow {
        let bundleID: String
        let name: String
        var policy: AppPolicy
        let locked: Bool
    }

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        show(.general)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showAboutPane() { show(.about) }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshLaunchState()
        reloadApps()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Chrome

    private func build() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        container.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(container)
        window.contentView = content
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        panes[.general] = generalPane()
        panes[.keys] = keysPane()
        panes[.sound] = soundPane()
        panes[.apps] = appsPane()
        panes[.about] = aboutPane()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue) else { return }
        show(pane)
    }

    private func show(_ pane: Pane) {
        guard let window, let view = panes[pane] else { return }
        current = pane
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        window.title = pane.title

        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Resize the window to the pane rather than padding every pane to the
        // largest. This is what System Settings does, and it is the difference
        // between "compact" and "mostly empty".
        let size = view.fittingSize
        var frame = window.frame
        let delta = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        frame.origin.y += frame.height - delta.height
        frame.size = delta
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    // MARK: - Layout helpers

    /// A settings row: right-aligned label, control, optional one-line hint.
    private func row(_ label: String, _ control: NSView, hint: String? = nil) -> [NSView] {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.textColor = .labelColor
        var right: NSView = control
        if let hint {
            let note = NSTextField(labelWithString: hint)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [control, note])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 3
            right = stack
        }
        return [title, right]
    }

    private func grid(_ rows: [[NSView]], width: CGFloat = 480) -> NSView {
        let g = NSGridView(views: rows)
        g.translatesAutoresizingMaskIntoConstraints = false
        g.rowSpacing = 12
        g.columnSpacing = 12
        g.column(at: 0).xPlacement = .trailing
        g.column(at: 0).width = 150
        for index in 0..<g.numberOfRows { g.row(at: index).yPlacement = .center }

        let host = NSView()
        host.addSubview(g)
        NSLayoutConstraint.activate([
            g.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
            g.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            g.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -20),
            g.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -24),
            host.widthAnchor.constraint(greaterThanOrEqualToConstant: width),
        ])
        return host
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    // MARK: - General

    private func generalPane() -> NSView {
        launchCheckbox = NSButton(checkboxWithTitle: L("settings.launchAtLogin"),
                                  target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchHint = NSTextField(labelWithString: "")
        launchHint.font = .systemFont(ofSize: 11)
        launchHint.textColor = .secondaryLabelColor
        launchHint.lineBreakMode = .byWordWrapping
        launchHint.maximumNumberOfLines = 2
        launchHint.preferredMaxLayoutWidth = 320

        let automatic = NSButton(checkboxWithTitle: L("settings.automatic"),
                                 target: self, action: #selector(toggleAutomatic(_:)))
        automatic.state = settings.automaticEnabled ? .on : .off

        let length = NSPopUpButton()
        for value in 4...8 { length.addItem(withTitle: L("settings.minimumLength.option", value)) }
        length.selectItem(at: settings.minimumLength - 4)
        length.target = self
        length.action = #selector(changeLength(_:))

        let switchLayout = NSButton(checkboxWithTitle: L("settings.switchLayout"),
                                    target: self, action: #selector(toggleSwitchLayout(_:)))
        switchLayout.state = settings.switchLayoutAfterReplacement ? .on : .off

        let launchStack = NSStackView(views: [launchCheckbox, launchHint])
        launchStack.orientation = .vertical
        launchStack.alignment = .leading
        launchStack.spacing = 3

        refreshLaunchState()

        // Shown only when access is granted on paper and dead in practice. The
        // person receiving this app has no other way out of that state: the
        // system dialog offers "Open Settings" and "Deny", and neither helps,
        // because the checkbox is already on. Only `tccutil reset` clears it.
        let permissions = Permissions.current(runProbe: false)
        var rows: [[NSView]] = []
        if permissions.looksStuck {
            let explain = NSTextField(wrappingLabelWithString: L("settings.permissions.stuck"))
            explain.font = .systemFont(ofSize: 11)
            explain.textColor = .secondaryLabelColor
            explain.preferredMaxLayoutWidth = 320
            let copy = NSButton(title: L("settings.permissions.copyCommand"),
                                target: self, action: #selector(copyResetCommand(_:)))
            let box = NSStackView(views: [explain, copy])
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 6
            rows.append(row(L("settings.permissions.label"), box))
        }

        rows += [
            row(L("settings.row.startup"), launchStack),
            row(L("settings.row.correction"), automatic),
            row(L("settings.minimumLength"), length, hint: L("settings.minimumLength.hint")),
            row("", switchLayout),
        ]
        return grid(rows)
    }

    @objc private func copyResetCommand(_ sender: Any?) {
        let command = "tccutil reset Accessibility com.lazyswitcher.app && "
                    + "tccutil reset ListenEvent com.lazyswitcher.app && "
                    + "tccutil reset PostEvent com.lazyswitcher.app"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        (sender as? NSButton)?.title = L("settings.permissions.copied")
    }

    private func refreshLaunchState() {
        guard launchCheckbox != nil else { return }
        let state = LaunchAtLogin.current
        launchCheckbox.state = state.isOn ? .on : .off
        launchCheckbox.isEnabled = true
        switch state {
        case .enabled:
            launchHint.stringValue = ""
        case .disabled:
            launchHint.stringValue = LaunchAtLogin.isInApplicationsFolder ? ""
                : L("settings.launchAtLogin.notInApplications")
        case .requiresApproval:
            launchHint.stringValue = L("settings.launchAtLogin.needsApproval")
        case .unavailable(let reason):
            launchCheckbox.isEnabled = false
            launchHint.stringValue = L("settings.launchAtLogin.unavailable",
                                       reason == .notFound ? L("launchAtLogin.reason.notFound")
                                                           : L("launchAtLogin.reason.unknown"))
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        if case .failure(let error) = LaunchAtLogin.set(sender.state == .on) {
            launchHint.stringValue = L("settings.launchAtLogin.failed", error.localizedDescription)
            NSSound.beep()
        }
        refreshLaunchState()
    }
    @objc private func toggleAutomatic(_ sender: NSButton) {
        settings.automaticEnabled = sender.state == .on
        app?.settingsDidChange()
    }
    @objc private func changeLength(_ sender: NSPopUpButton) {
        settings.minimumLength = sender.indexOfSelectedItem + 4
        app?.settingsDidChange()
    }
    @objc private func toggleSwitchLayout(_ sender: NSButton) {
        settings.switchLayoutAfterReplacement = sender.state == .on
        app?.settingsDidChange()
    }

    // MARK: - Keys

    private func keysPane() -> NSView {
        let popUp = NSPopUpButton()
        for style in HotkeyStyle.allCases { popUp.addItem(withTitle: style.title) }
        popUp.selectItem(at: HotkeyStyle.allCases.firstIndex(of: settings.hotkeyStyle) ?? 0)
        popUp.target = self
        popUp.action = #selector(changeHotkey(_:))

        hotkeyHint = NSTextField(wrappingLabelWithString: settings.hotkeyStyle.explanation)
        hotkeyHint.font = .systemFont(ofSize: 11)
        hotkeyHint.textColor = .secondaryLabelColor
        hotkeyHint.preferredMaxLayoutWidth = 320

        let what = NSTextField(wrappingLabelWithString: L("settings.keys.what"))
        what.font = .systemFont(ofSize: 11)
        what.textColor = .secondaryLabelColor
        what.preferredMaxLayoutWidth = 320

        let pause = NSTextField(labelWithString: L("settings.keys.pause"))

        return grid([
            row(L("settings.keys.action"), popUp),
            row("", hotkeyHint),
            row(L("settings.keys.does"), what),
            row(L("settings.keys.pauseLabel"), pause),
        ])
    }

    @objc private func changeHotkey(_ sender: NSPopUpButton) {
        let style = HotkeyStyle.allCases[sender.indexOfSelectedItem]
        settings.hotkeyStyle = style
        hotkeyHint.stringValue = style.explanation
        app?.settingsDidChange()
    }

    // MARK: - Sound

    private func soundPane() -> NSView {
        let enabled = NSButton(checkboxWithTitle: L("settings.sound.enabled"),
                               target: self, action: #selector(toggleSound(_:)))
        enabled.state = settings.soundEnabled ? .on : .off

        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: Settings.availableSounds)
        popUp.selectItem(withTitle: settings.soundName)
        popUp.target = self
        popUp.action = #selector(changeSound(_:))

        let slider = NSSlider(value: Double(settings.soundVolume), minValue: 0, maxValue: 1,
                              target: self, action: #selector(changeVolume(_:)))
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        return grid([
            row(L("settings.row.signal"), enabled),
            row(L("settings.sound.choose"), popUp, hint: L("settings.sound.hint")),
            row(L("settings.sound.volume"), slider),
        ])
    }

    @objc private func toggleSound(_ sender: NSButton) { settings.soundEnabled = sender.state == .on }
    @objc private func changeSound(_ sender: NSPopUpButton) {
        settings.soundName = sender.titleOfSelectedItem ?? "Tink"
        settings.playFeedbackSound()
    }
    @objc private func changeVolume(_ sender: NSSlider) {
        settings.soundVolume = Float(sender.doubleValue)
        settings.playFeedbackSound()
    }

    // MARK: - Apps

    private func appsPane() -> NSView {
        let unidentified = NSButton(checkboxWithTitle: L("settings.apps.unidentified"),
                                    target: self, action: #selector(toggleUnidentified(_:)))
        unidentified.state = settings.actInUnidentifiedFields ? .on : .off
        let unidentifiedHint = NSTextField(wrappingLabelWithString: L("settings.apps.unidentified.hint"))
        unidentifiedHint.font = .systemFont(ofSize: 11)
        unidentifiedHint.textColor = .secondaryLabelColor
        unidentifiedHint.preferredMaxLayoutWidth = 320

        appTable = NSTableView()
        appTable.headerView = nil
        appTable.rowHeight = 26
        appTable.style = .inset
        appTable.dataSource = self
        appTable.delegate = self
        let name = NSTableColumn(identifier: .init("app")); name.width = 200
        let mode = NSTableColumn(identifier: .init("policy")); mode.width = 150
        appTable.addTableColumn(name)
        appTable.addTableColumn(mode)

        let scroll = NSScrollView()
        scroll.documentView = appTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let toggle = NSButton(checkboxWithTitle: L("settings.apps.showProtected"),
                              target: self, action: #selector(toggleProtected(_:)))
        toggle.state = .off
        toggle.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [scroll, toggle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let unidentifiedStack = NSStackView(views: [unidentified, unidentifiedHint])
        unidentifiedStack.orientation = .vertical
        unidentifiedStack.alignment = .leading
        unidentifiedStack.spacing = 3

        reloadApps()
        return grid([
            row(L("settings.apps.title"), stack),
            row(L("settings.apps.risky"), unidentifiedStack),
        ])
    }

    @objc private func toggleUnidentified(_ sender: NSButton) {
        settings.actInUnidentifiedFields = sender.state == .on
        app?.settingsDidChange()
    }

    @objc private func toggleProtected(_ sender: NSButton) {
        showProtected = sender.state == .on
        reloadApps()
    }

    /// Running apps only, and by default only the ones worth showing.
    ///
    /// The first version listed every locked exclusion whether it was running or
    /// not, which made the longest list in the app out of rows nobody can change.
    /// They are one checkbox away for anyone who wants the reassurance.
    private func reloadApps() {
        guard appTable != nil, let policies = app?.policies else { return }
        var rows: [AppRow] = []
        var seen = Set<String>()
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let id = running.bundleIdentifier, seen.insert(id).inserted else { continue }
            let locked = policies.isLocked(id)
            if locked && !showProtected { continue }
            rows.append(AppRow(bundleID: id, name: running.localizedName ?? id,
                               policy: policies.policy(for: id), locked: locked))
        }
        appRows = rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        appTable.reloadData()
    }

    // MARK: - About

    private var bannerView: NSImageView?
    private var bannerRow: NSStackView?

    private func aboutPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let banner = NSImage(named: "Banner") {
            let image = NSImageView(image: banner)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 460).isActive = true
            image.heightAnchor.constraint(equalToConstant: 230).isActive = true
            image.wantsLayer = true
            image.layer?.cornerRadius = 10
            image.layer?.masksToBounds = true

            let hide = NSButton(title: L("about.hideBanner"), target: self,
                                action: #selector(toggleBanner(_:)))
            hide.bezelStyle = .accessoryBarAction
            hide.controlSize = .small

            let row = NSStackView(views: [image, hide])
            row.orientation = .vertical
            row.alignment = .centerX
            row.spacing = 6
            bannerView = image
            bannerRow = row
            stack.addArrangedSubview(row)
            row.isHidden = settings.bannerHidden
        }

        let name = NSTextField(labelWithString: "Lazy Switcher")
        name.font = .systemFont(ofSize: 20, weight: .semibold)

        let version = NSTextField(labelWithString: L("about.version", UpdateChecker.currentVersion))
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor

        let facts = NSTextField(wrappingLabelWithString: L("about.facts"))
        facts.font = .systemFont(ofSize: 11)
        facts.textColor = .secondaryLabelColor
        facts.alignment = .center
        facts.preferredMaxLayoutWidth = 420

        updateStatus = NSTextField(labelWithString: "")
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor

        let checkNow = NSButton(title: L("settings.updates.checkNow"), target: self,
                                action: #selector(checkNow(_:)))
        let openPage = NSButton(title: L("settings.updates.openPage"), target: self,
                                action: #selector(openReleases(_:)))
        let buttons = NSStackView(views: [checkNow, openPage])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let auto = NSButton(checkboxWithTitle: L("settings.updates.automatic"),
                            target: self, action: #selector(toggleAutoUpdates(_:)))
        auto.state = settings.checkUpdatesAutomatically ? .on : .off
        auto.font = .systemFont(ofSize: 11)

        let showBanner = NSButton(title: L("about.showBanner"), target: self,
                                  action: #selector(toggleBanner(_:)))
        showBanner.bezelStyle = .accessoryBarAction
        showBanner.controlSize = .small
        showBanner.isHidden = !settings.bannerHidden
        bannerToggleButton = showBanner

        let links = NSTextField(wrappingLabelWithString: L("about.links"))
        links.font = .systemFont(ofSize: 11)
        links.textColor = .tertiaryLabelColor
        links.alignment = .center
        links.preferredMaxLayoutWidth = 420

        let rows: [NSView] = [name, version, showBanner, facts, buttons, auto, updateStatus, links]
        for view in rows {
            stack.addArrangedSubview(view)
        }
        return stack
    }

    private var bannerToggleButton: NSButton?

    @objc private func toggleBanner(_ sender: Any?) {
        settings.bannerHidden.toggle()
        bannerRow?.isHidden = settings.bannerHidden
        bannerToggleButton?.isHidden = !settings.bannerHidden
        if current == .about { show(.about) }
    }

    @objc private func toggleAutoUpdates(_ sender: NSButton) {
        settings.checkUpdatesAutomatically = sender.state == .on
    }
    @objc private func openReleases(_ sender: Any?) {
        NSWorkspace.shared.open(UpdateChecker.releasesPage)
    }
    @objc private func checkNow(_ sender: Any?) {
        updateStatus.stringValue = L("settings.updates.checking")
        UpdateChecker.check { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .upToDate(let current):
                updateStatus.stringValue = L("settings.updates.upToDate", current)
            case .updateAvailable(let latest, let current):
                updateStatus.stringValue = L("settings.updates.available", latest, current)
            case .failed(let reason):
                updateStatus.stringValue = L("settings.updates.failed", reason)
            }
        }
    }
}

// MARK: - App table

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { appRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let entry = appRows[row]
        if tableColumn?.identifier.rawValue == "app" {
            let label = NSTextField(labelWithString: entry.locked ? "🔒 \(entry.name)" : entry.name)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        if entry.locked {
            let label = NSTextField(labelWithString: L("settings.apps.mode.disabled"))
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            return label
        }
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: [L("settings.apps.mode.disabled"),
                                    L("settings.apps.mode.hotkeyOnly"),
                                    L("settings.apps.mode.automatic")])
        popUp.selectItem(at: Int(entry.policy.rawValue))
        popUp.tag = row
        popUp.target = self
        popUp.action = #selector(changePolicy(_:))
        popUp.font = .systemFont(ofSize: 11)
        popUp.controlSize = .small
        popUp.isBordered = false
        return popUp
    }

    @objc private func changePolicy(_ sender: NSPopUpButton) {
        let entry = appRows[sender.tag]
        guard let policy = AppPolicy(rawValue: UInt8(sender.indexOfSelectedItem)),
              app?.policies.setPolicy(policy, for: entry.bundleID) == true else {
            sender.selectItem(at: Int(entry.policy.rawValue))
            NSSound.beep()
            return
        }
        Settings.shared.store(policy: policy, for: entry.bundleID)
        appRows[sender.tag].policy = policy
        app?.settingsDidChange()
    }
}
