import AppKit

/// The whole of M0: a window that answers the questions the roadmap says must be
/// answered before any real code is written.
///
/// Note what it deliberately does NOT do: it shows the last key code on screen and
/// nowhere else. No print, no os_log, no file. CLAUDE.md rule 1 has no debug
/// exception, and a diagnostics screen is exactly where that rule gets broken by
/// accident.
final class DiagnosticsWindowController: NSWindowController {

    private let tap: KeyTapService
    private let secureInput: SecureInputMonitor
    private let text = NSTextView()
    private var refreshTimer: Timer?
    private var stallField: NSTextField!
    private var stallResult = "не запускался"
    private var stallBaseline: UInt64 = 0

    init(tap: KeyTapService, secureInput: SecureInputMonitor) {
        self.tap = tap
        self.secureInput = secureInput

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Lazy Switcher — диагностика M0"
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let window else { return }

        text.isEditable = false
        text.isSelectable = true
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 14, height: 12)

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stallField = NSTextField(string: "1000")
        stallField.translatesAutoresizingMaskIntoConstraints = false

        let stallLabel = NSTextField(labelWithString: "Задержать колбэк, мс:")
        stallLabel.translatesAutoresizingMaskIntoConstraints = false

        let stallButton = NSButton(title: "Проверить порог отключения",
                                   target: self, action: #selector(runStallExperiment))
        stallButton.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: "Скопировать отчёт",
                                  target: self, action: #selector(copyReport))
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(stallLabel)
        content.addSubview(stallField)
        content.addSubview(stallButton)
        content.addSubview(copyButton)
        window.contentView = content

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: stallLabel.topAnchor, constant: -12),

            stallLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stallLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            stallField.leadingAnchor.constraint(equalTo: stallLabel.trailingAnchor, constant: 8),
            stallField.centerYAnchor.constraint(equalTo: stallLabel.centerYAnchor),
            stallField.widthAnchor.constraint(equalToConstant: 70),
            stallButton.leadingAnchor.constraint(equalTo: stallField.trailingAnchor, constant: 8),
            stallButton.centerYAnchor.constraint(equalTo: stallLabel.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            copyButton.centerYAnchor.constraint(equalTo: stallLabel.centerYAnchor),
        ])

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
    }

    // MARK: - The experiment from roadmap M0

    /// Stalls the tap callback long enough for macOS to lose patience, then reports
    /// whether `.tapDisabledByTimeout` actually arrived. Apple does not document
    /// the threshold, so the only way to know it is to walk into it.
    @objc private func runStallExperiment() {
        let ms = UInt64(stallField.integerValue)
        guard ms > 0 else { return }
        stallBaseline = tap.timeoutDisableCount.value
        stallResult = "идёт: следующее нажатие клавиши задержится на \(ms) мс…"
        tap.injectedStallMilliseconds.value = ms
        refresh()

        // One stalled event is enough; disarm shortly after so the machine stays usable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            tap.injectedStallMilliseconds.value = 0
            let fired = tap.timeoutDisableCount.value - stallBaseline
            stallResult = fired > 0
                ? "при \(ms) мс система отключила tap (\(fired)×) — и он был включён обратно"
                : "при \(ms) мс отключения не было"
            refresh()
        }
    }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
    }

    // MARK: - Report

    private func refresh() {
        let selected = text.selectedRange()
        text.string = report()
        if selected.location + selected.length <= text.string.utf16.count {
            text.setSelectedRange(selected)
        }
    }

    private func report() -> String {
        let p = Permissions.current(runProbe: false)
        let secure = secureInput.isEnabled
        let lastKey = tap.lastKeyCode.value
        let bundle = Bundle.main

        var out = ""
        func section(_ title: String) { out += "\n\(title)\n" + String(repeating: "─", count: 58) + "\n" }
        func row(_ k: String, _ v: String) { out += k.padding(toLength: 34, withPad: " ", startingAt: 0) + v + "\n" }
        func flag(_ b: Bool) -> String { b ? "да" : "нет" }

        section("СБОРКА")
        row("bundle ID", bundle.bundleIdentifier ?? "—")
        row("версия", (bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            + " (" + (bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—") + ")")
        row("путь", bundle.bundlePath)
        row("в /Applications", flag(bundle.bundlePath.hasPrefix("/Applications")))
        row("App Translocation", flag(bundle.bundlePath.contains("/AppTranslocation/")))

        section("РАЗРЕШЕНИЯ")
        row("CGPreflightListenEventAccess", flag(p.canListen))
        row("CGPreflightPostEventAccess", flag(p.canPost))
        row("AXIsProcessTrusted (не решает)", flag(p.axTrusted))
        row("готовы к работе", flag(p.isUsable))

        section("EVENT TAP")
        row("запущен", flag(tap.isRunning))
        row("keyDown всего", "\(tap.keyDownCount.value)")
        row("flagsChanged всего", "\(tap.flagsChangedCount.value)")
        row("последний keyCode", lastKey == UInt64.max ? "—" : "\(lastKey)")
        row("последние флаги", lastKey == UInt64.max ? "—" : String(format: "0x%08X", tap.lastFlags.value))
        row("отключений по таймауту", "\(tap.timeoutDisableCount.value)")
        row("отключений по вводу", "\(tap.userInputDisableCount.value)")
        row("оживлений сторожем", "\(tap.watchdogRevivalCount.value)")
        row("эксперимент с задержкой", stallResult)

        section("SECURE INPUT — ГЛАВНАЯ ПРОВЕРКА")
        row("IsSecureEventInputEnabled", flag(secure))
        if secure, let who = SecureInputMonitor.likelyResponsibleProcess() {
            row("похоже, включил", "\(who.name) (pid \(who.pid))")
        }
        row("keyDown при Secure Input", "\(tap.keyDownDuringSecureInput.value)   ← обязан быть 0")
        row("flagsChanged при Secure Input", "\(tap.flagsChangedDuringSecureInput.value)   ← ожидаем рост")

        out += """

  Как проверить асимметрию, на которой держится безопасность двойного Shift:
    1. В Терминале запустить  python3 -c 'import getpass; getpass.getpass()'
    2. Понажимать буквы и отдельно — Shift
    3. Вернуться сюда: keyDown при Secure Input должен остаться 0,
       а flagsChanged при Secure Input — вырасти.
    Если вырастут оба — вся модель безопасности неверна, и это надо знать сейчас.

"""
        return out
    }
}
