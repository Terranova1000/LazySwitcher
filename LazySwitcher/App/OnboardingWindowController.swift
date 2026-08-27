import AppKit
import ServiceManagement

/// First run. Three screens, and the second one is the whole point.
///
/// The measure of success is that somebody who read nothing gets to a working
/// state. Two things stand in the way, and neither is the app's fault: macOS
/// refuses to open an unnotarised app until you dig through Settings, and the
/// accessibility grant does not take effect until the app restarts.
///
/// So this screen does the digging it can and is honest about the rest. It also
/// says plainly what the app can see, because a program that watches every
/// keystroke and glosses over that has not earned the grant it is asking for.
final class OnboardingWindowController: NSWindowController {

    private weak var app: AppDelegate?
    private var stepIndex = 0
    private var body: NSTextField!
    private var title: NSTextField!
    private var primary: NSButton!
    private var secondary: NSButton!
    private var poll: Timer?

    private struct Step {
        let title: String
        let text: String
        let primaryTitle: String
        let secondaryTitle: String?
    }

    private let steps: [Step] = [
        Step(title: "Lazy Switcher",
             text: """
             Замечает текст, набранный не в той раскладке, и исправляет его.

             ghbdtn  →  привет
             руддщ   →  hello

             Заодно переключает раскладку, чтобы продолжение фразы печаталось \
             уже правильно.

             Бесплатно. Работает на вашем компьютере. Ничего из набранного не \
             записывается на диск и никуда не отправляется.
             """,
             primaryTitle: "Дальше", secondaryTitle: nil),

        Step(title: "Нужен доступ",
             text: """
             macOS не разрешит программе видеть, что вы набираете, без вашего \
             согласия. Это правильно, и вот что согласие означает на практике.

             Приложение видит нажатия клавиш. Поэтому оно устроено так, что \
             набранное живёт в оперативной памяти несколько секунд и стирается — \
             ни в файл, ни в журнал, ни в отчёт об ошибке оно не попадает.

             Чего оно НЕ видит: когда система включает защищённый режим ввода — \
             в окне входа, в менеджере паролей, в поле пароля обычного \
             приложения — нажатия до него просто не доходят. Не «мы не смотрим», \
             а физически не приходят.

             Отдельно и честно: на сайтах macOS этот режим не включает ни в одном \
             браузере. Там поле пароля распознаётся по разметке страницы — это \
             работает в Safari, а в Chrome и Firefox не работает, и потому там по \
             умолчанию доступно только ручное исправление.

             Нажмите кнопку, включите «Lazy Switcher» в списке — и вернитесь сюда.
             """,
             primaryTitle: "Открыть Универсальный доступ", secondaryTitle: "Пропустить"),

        Step(title: "Готово",
             text: """
             Всё работает.

             Наберите слово не в той раскладке и поставьте пробел — оно \
             исправится само, если длиннее четырёх символов.

             Двойное нажатие Shift:
             • есть выделенный текст — переведётся всё выделение;
             • только что была замена — откат, и слово запомнится как «не менять»;
             • иначе — исправится последнее слово.

             Левый и правый Shift вместе — пауза.

             Всё это меняется в настройках: и жест, и звук, и список приложений.
             """,
             primaryTitle: "Начать", secondaryTitle: "Открыть настройки"),
    ]

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Первый запуск"
        window.center()
        super.init(window: window)
        build()
        show(step: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let window else { return }
        title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        body = NSTextField(wrappingLabelWithString: "")
        body.font = .systemFont(ofSize: 13)
        body.preferredMaxLayoutWidth = 452

        primary = NSButton(title: "", target: self, action: #selector(advance(_:)))
        primary.keyEquivalent = "\r"
        secondary = NSButton(title: "", target: self, action: #selector(secondaryAction(_:)))

        let buttons = NSStackView(views: [secondary, primary])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, body, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 24, right: 32)

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func show(step index: Int) {
        stepIndex = min(index, steps.count - 1)
        let step = steps[stepIndex]
        title.stringValue = step.title
        body.stringValue = step.text
        primary.title = step.primaryTitle
        secondary.title = step.secondaryTitle ?? ""
        secondary.isHidden = step.secondaryTitle == nil
        if stepIndex == 1 { startWatchingForGrant() } else { poll?.invalidate() }
    }

    @objc private func advance(_ sender: Any?) {
        switch stepIndex {
        case 0:
            show(step: Permissions.current(runProbe: false).isUsable ? 2 : 1)
        case 1:
            Permissions.request()
            Permissions.openAccessibilitySettings()
        default:
            poll?.invalidate()
            close()
        }
    }

    @objc private func secondaryAction(_ sender: Any?) {
        if stepIndex == 1 { show(step: 2) } else { app?.showSettings(nil); close() }
    }

    /// Watches for the grant and restarts the app when it arrives.
    ///
    /// Restarting is not laziness — it is required. `CGPreflight*` answers from
    /// a cache created inside the process and never refreshed, so an app that is
    /// already running keeps being told it has no access no matter how long it
    /// waits (00-DECISIONS.md, Н6). Every tool in this category either restarts
    /// itself or tells the user to, and doing it silently is the kinder half of
    /// that choice.
    private func startWatchingForGrant() {
        poll?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            self?.poll?.invalidate()
            self?.relaunch()
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
