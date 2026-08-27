import AppKit

/// The settings window. AppKit, four tabs, deliberately small.
///
/// The measure is not "how much can be configured" but "does each switch solve a
/// problem somebody actually has". Punto shipped ninety-six checkboxes and the
/// complaint was never that it had too few.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private weak var app: AppDelegate?
    private let settings = Settings.shared

    private var soundPopUp: NSPopUpButton!
    private var volumeSlider: NSSlider!
    private var lengthPopUp: NSPopUpButton!
    private var unidentifiedCheckbox: NSButton!
    private var appList: NSTableView!
    private var appRows: [(bundleID: String, name: String, policy: AppPolicy, locked: Bool)] = []

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("settings.window.title")
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The user may have changed Login Items in System Settings while this
    /// window was closed, so the state is re-read every time it appears.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshLaunchState()
    }

    // MARK: - Layout

    private func build() {
        guard let window else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        tabs.addTabViewItem(tab(L("settings.tab.general"), view: generalTab()))
        tabs.addTabViewItem(tab(L("settings.tab.keys"), view: keysTab()))
        tabs.addTabViewItem(tab(L("settings.tab.sound"), view: soundTab()))
        tabs.addTabViewItem(tab(L("settings.tab.apps"), view: appsTab()))
        tabs.addTabViewItem(tab(L("settings.tab.updates"), view: updatesTab()))

        let content = NSView()
        content.addSubview(tabs)
        window.contentView = content
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    private func tab(_ title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = title
        item.view = view
        return item
    }

    private func column(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        return stack
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 480
        return label
    }

    // MARK: - General

    private var launchCheckbox: NSButton!
    private var launchHint: NSTextField!

    private func generalTab() -> NSView {
        launchCheckbox = NSButton(checkboxWithTitle: L("settings.launchAtLogin"),
                                  target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchHint = hint("")
        refreshLaunchState()

        let automatic = NSButton(checkboxWithTitle: L("settings.automatic"),
                                 target: self, action: #selector(toggleAutomatic(_:)))
        automatic.state = settings.automaticEnabled ? .on : .off

        lengthPopUp = NSPopUpButton()
        for length in 4...8 { lengthPopUp.addItem(withTitle: L("settings.minimumLength.option", length)) }
        lengthPopUp.selectItem(at: settings.minimumLength - 4)
        lengthPopUp.target = self
        lengthPopUp.action = #selector(changeLength(_:))

        let lengthRow = NSStackView(views: [NSTextField(labelWithString: L("settings.minimumLength")), lengthPopUp])
        lengthRow.orientation = .horizontal
        lengthRow.spacing = 8

        let switchLayout = NSButton(checkboxWithTitle: L("settings.switchLayout"),
                                    target: self, action: #selector(toggleSwitchLayout(_:)))
        switchLayout.state = settings.switchLayoutAfterReplacement ? .on : .off

        return column([
            launchCheckbox,
            launchHint,
            NSBox(),
            automatic,
            lengthRow,
            hint(L("settings.minimumLength.hint")),
            switchLayout,
        ])
    }

    /// Re-reads from the system rather than trusting what we last set.
    private func refreshLaunchState() {
        let state = LaunchAtLogin.current
        launchCheckbox.state = state.isOn ? .on : .off
        switch state {
        case .enabled:
            launchCheckbox.isEnabled = true
            launchHint.stringValue = ""
        case .disabled:
            launchCheckbox.isEnabled = true
            launchHint.stringValue = LaunchAtLogin.isInApplicationsFolder ? ""
                : L("settings.launchAtLogin.notInApplications")
        case .requiresApproval:
            launchCheckbox.isEnabled = true
            launchHint.stringValue = L("settings.launchAtLogin.needsApproval")
        case .unavailable(let reason):
            launchCheckbox.isEnabled = false
            launchHint.stringValue = L("settings.launchAtLogin.unavailable", reason)
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let wanted = sender.state == .on
        if case .failure(let error) = LaunchAtLogin.set(wanted) {
            launchHint.stringValue = L("settings.launchAtLogin.failed", error.localizedDescription)
            NSSound.beep()
        }
        // Whatever we asked for, show what the system actually did.
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

    private var hotkeyPopUp: NSPopUpButton!
    private var hotkeyHint: NSTextField!

    private func keysTab() -> NSView {
        hotkeyPopUp = NSPopUpButton()
        for style in HotkeyStyle.allCases { hotkeyPopUp.addItem(withTitle: style.title) }
        hotkeyPopUp.selectItem(at: HotkeyStyle.allCases.firstIndex(of: settings.hotkeyStyle) ?? 0)
        hotkeyPopUp.target = self
        hotkeyPopUp.action = #selector(changeHotkey(_:))

        let row = NSStackView(views: [NSTextField(labelWithString: L("settings.keys.action")), hotkeyPopUp])
        row.orientation = .horizontal
        row.spacing = 8

        hotkeyHint = hint(settings.hotkeyStyle.explanation)

        return column([
            row,
            hotkeyHint,
            NSBox(),
            hint(L("settings.keys.hint")),
        ])
    }

    @objc private func changeHotkey(_ sender: NSPopUpButton) {
        let style = HotkeyStyle.allCases[sender.indexOfSelectedItem]
        settings.hotkeyStyle = style
        hotkeyHint.stringValue = style.explanation
        app?.settingsDidChange()
    }

    // MARK: - Updates

    private var updateStatus: NSTextField!

    private func updatesTab() -> NSView {
        let automatic = NSButton(checkboxWithTitle: L("settings.updates.automatic"),
                                 target: self, action: #selector(toggleAutoUpdates(_:)))
        automatic.state = settings.checkUpdatesAutomatically ? .on : .off

        let checkNow = NSButton(title: L("settings.updates.checkNow"), target: self, action: #selector(checkNow(_:)))
        let openPage = NSButton(title: L("settings.updates.openPage"),
                                target: self, action: #selector(openReleases(_:)))
        let buttons = NSStackView(views: [checkNow, openPage])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        updateStatus = NSTextField(labelWithString: L("settings.updates.version", UpdateChecker.currentVersion))

        return column([
            updateStatus,
            buttons,
            NSBox(),
            automatic,
            hint(L("settings.updates.hint")),
        ])
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

    // MARK: - Sound

    private func soundTab() -> NSView {
        let enabled = NSButton(checkboxWithTitle: L("settings.sound.enabled"),
                               target: self, action: #selector(toggleSound(_:)))
        enabled.state = settings.soundEnabled ? .on : .off

        soundPopUp = NSPopUpButton()
        soundPopUp.addItems(withTitles: Settings.availableSounds)
        soundPopUp.selectItem(withTitle: settings.soundName)
        soundPopUp.target = self
        soundPopUp.action = #selector(changeSound(_:))

        let preview = NSButton(title: L("settings.sound.preview"), target: self, action: #selector(previewSound(_:)))
        let soundRow = NSStackView(views: [NSTextField(labelWithString: L("settings.sound.choose")), soundPopUp, preview])
        soundRow.orientation = .horizontal
        soundRow.spacing = 8

        volumeSlider = NSSlider(value: Double(settings.soundVolume), minValue: 0, maxValue: 1,
                                target: self, action: #selector(changeVolume(_:)))
        volumeSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let volumeRow = NSStackView(views: [NSTextField(labelWithString: L("settings.sound.volume")), volumeSlider])
        volumeRow.orientation = .horizontal
        volumeRow.spacing = 8

        return column([
            enabled, soundRow, volumeRow,
            hint(L("settings.sound.hint")),
        ])
    }

    @objc private func toggleSound(_ sender: NSButton) { settings.soundEnabled = sender.state == .on }
    @objc private func changeSound(_ sender: NSPopUpButton) {
        settings.soundName = sender.titleOfSelectedItem ?? "Tink"
        settings.playFeedbackSound()
    }
    @objc private func changeVolume(_ sender: NSSlider) {
        settings.soundVolume = Float(sender.doubleValue)
    }
    @objc private func previewSound(_ sender: Any?) { settings.playFeedbackSound() }

    // MARK: - Apps

    private func appsTab() -> NSView {
        unidentifiedCheckbox = NSButton(
            checkboxWithTitle: L("settings.apps.unidentified"),
            target: self, action: #selector(toggleUnidentified(_:)))
        unidentifiedCheckbox.state = settings.actInUnidentifiedFields ? .on : .off

        appList = NSTableView()
        appList.addTableColumn({
            let c = NSTableColumn(identifier: .init("app")); c.title = L("settings.apps.column.app"); c.width = 260; return c
        }())
        appList.addTableColumn({
            let c = NSTableColumn(identifier: .init("policy")); c.title = L("settings.apps.column.mode"); c.width = 200; return c
        }())
        appList.dataSource = self
        appList.delegate = self
        appList.rowHeight = 22

        let scroll = NSScrollView()
        scroll.documentView = appList
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 210).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 500).isActive = true

        reloadApps()

        return column([
            unidentifiedCheckbox,
            hint(L("settings.apps.unidentified.hint")),
            NSTextField(labelWithString: L("settings.apps.title")),
            scroll,
            hint(L("settings.apps.locked.hint")),
        ])
    }

    @objc private func toggleUnidentified(_ sender: NSButton) {
        settings.actInUnidentifiedFields = sender.state == .on
        app?.settingsDidChange()
        reloadApps()
    }

    private func reloadApps() {
        var rows: [(String, String, AppPolicy, Bool)] = []
        var seen = Set<String>()

        for running in NSWorkspace.shared.runningApplications
        where running.activationPolicy == .regular {
            guard let id = running.bundleIdentifier, seen.insert(id).inserted else { continue }
            rows.append((id, running.localizedName ?? id,
                         app?.policies.policy(for: id) ?? .automatic,
                         app?.policies.isLocked(id) ?? false))
        }
        // Locked apps that are not running still belong in the list: seeing that
        // Terminal is permanently excluded is the reassurance, and it is useless
        // if it only appears while Terminal happens to be open.
        for id in AppPolicyStore.lockedExclusions.sorted() where seen.insert(id).inserted {
            rows.append((id, id, .disabled, true))
        }
        appRows = rows.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        appList.reloadData()
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
            return label
        }
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: [L("settings.apps.mode.disabled"),
                                    L("settings.apps.mode.hotkeyOnly"),
                                    L("settings.apps.mode.automatic")])
        popUp.selectItem(at: Int(entry.policy.rawValue))
        popUp.isEnabled = !entry.locked
        popUp.tag = row
        popUp.target = self
        popUp.action = #selector(changePolicy(_:))
        popUp.font = .systemFont(ofSize: 11)
        return popUp
    }

    @objc private func changePolicy(_ sender: NSPopUpButton) {
        let entry = appRows[sender.tag]
        guard let policy = AppPolicy(rawValue: UInt8(sender.indexOfSelectedItem)) else { return }
        guard app?.policies.setPolicy(policy, for: entry.bundleID) == true else {
            // Locked. Put the menu back where it was rather than lying about it.
            sender.selectItem(at: Int(entry.policy.rawValue))
            NSSound.beep()
            return
        }
        Settings.shared.store(policy: policy, for: entry.bundleID)
        appRows[sender.tag].policy = policy
        app?.settingsDidChange()
    }
}
