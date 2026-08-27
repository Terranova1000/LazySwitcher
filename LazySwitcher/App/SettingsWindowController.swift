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
        window.title = "Настройки Lazy Switcher"
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func build() {
        guard let window else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false

        tabs.addTabViewItem(tab("Основное", view: generalTab()))
        tabs.addTabViewItem(tab("Звук", view: soundTab()))
        tabs.addTabViewItem(tab("Приложения", view: appsTab()))

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

    private func generalTab() -> NSView {
        let automatic = NSButton(checkboxWithTitle: "Исправлять автоматически",
                                 target: self, action: #selector(toggleAutomatic(_:)))
        automatic.state = settings.automaticEnabled ? .on : .off

        lengthPopUp = NSPopUpButton()
        for length in 4...8 { lengthPopUp.addItem(withTitle: "от \(length) символов") }
        lengthPopUp.selectItem(at: settings.minimumLength - 4)
        lengthPopUp.target = self
        lengthPopUp.action = #selector(changeLength(_:))

        let lengthRow = NSStackView(views: [NSTextField(labelWithString: "Минимальная длина слова:"), lengthPopUp])
        lengthRow.orientation = .horizontal
        lengthRow.spacing = 8

        let switchLayout = NSButton(checkboxWithTitle: "Переключать раскладку после исправления",
                                    target: self, action: #selector(toggleSwitchLayout(_:)))
        switchLayout.state = settings.switchLayoutAfterReplacement ? .on : .off

        return column([
            automatic,
            lengthRow,
            hint("На пяти символах ложных срабатываний ноль по замерам на 25 тысячах слов; "
               + "на четырёх — примерно одно на сто пятнадцать слов. Короткие слова всё равно "
               + "исправляются, если следующее слово подтверждает раскладку."),
            switchLayout,
            NSBox(),
            NSTextField(labelWithString: "Горячие клавиши"),
            hint("Двойное нажатие Shift — исправить последнее слово или выделенный текст. "
               + "Повторно в течение 5 секунд — откат.\n"
               + "Левый и правый Shift вместе — пауза."),
        ])
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

    // MARK: - Sound

    private func soundTab() -> NSView {
        let enabled = NSButton(checkboxWithTitle: "Звук при исправлении",
                               target: self, action: #selector(toggleSound(_:)))
        enabled.state = settings.soundEnabled ? .on : .off

        soundPopUp = NSPopUpButton()
        soundPopUp.addItems(withTitles: Settings.availableSounds)
        soundPopUp.selectItem(withTitle: settings.soundName)
        soundPopUp.target = self
        soundPopUp.action = #selector(changeSound(_:))

        let preview = NSButton(title: "Прослушать", target: self, action: #selector(previewSound(_:)))
        let soundRow = NSStackView(views: [NSTextField(labelWithString: "Звук:"), soundPopUp, preview])
        soundRow.orientation = .horizontal
        soundRow.spacing = 8

        volumeSlider = NSSlider(value: Double(settings.soundVolume), minValue: 0, maxValue: 1,
                                target: self, action: #selector(changeVolume(_:)))
        volumeSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let volumeRow = NSStackView(views: [NSTextField(labelWithString: "Громкость:"), volumeSlider])
        volumeRow.orientation = .horizontal
        volumeRow.spacing = 8

        return column([
            enabled, soundRow, volumeRow,
            hint("Звук — самый дешёвый способ заметить, что текст изменился, не отводя глаз "
               + "от того, что печатаете. Если мешает — выключите, иконка в строке меню "
               + "мигает всё равно."),
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
            checkboxWithTitle: "Работать и там, где тип поля определить не удаётся",
            target: self, action: #selector(toggleUnidentified(_:)))
        unidentifiedCheckbox.state = settings.actInUnidentifiedFields ? .on : .off

        appList = NSTableView()
        appList.addTableColumn({
            let c = NSTableColumn(identifier: .init("app")); c.title = "Приложение"; c.width = 260; return c
        }())
        appList.addTableColumn({
            let c = NSTableColumn(identifier: .init("policy")); c.title = "Режим"; c.width = 200; return c
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
            hint("⚠️ В Chrome и Firefox нет ни одного признака поля пароля — ни в разметке "
               + "доступности, ни через защищённый режим ввода macOS. Это проверено, не "
               + "предположение. Пока эта галочка снята, там работает только двойной Shift, "
               + "и вы сами решаете, куда его нажать. Если включить — автозамена сможет "
               + "сработать и в поле пароля."),
            NSTextField(labelWithString: "Приложения"),
            scroll,
            hint("Терминалы, менеджеры паролей и виртуальные машины помечены замком и "
               + "изменению не подлежат."),
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
        popUp.addItems(withTitles: ["выключено", "только по хоткею", "автоматически"])
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
