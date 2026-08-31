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
    private var banner: NSImageView!
    private var primary: NSButton!
    private var secondary: NSButton!
    private var poll: Timer?

    private struct Step {
        let title: String
        let text: String
        let primaryTitle: String
        let secondaryTitle: String?
    }

    private let steps: [Step] = (1...3).map { index in
        Step(title: L("onboarding.step\(index).title"),
             text: L("onboarding.step\(index).body"),
             primaryTitle: L("onboarding.step\(index).primary"),
             secondaryTitle: index == 1 ? nil : L("onboarding.step\(index).secondary"))
    }

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("onboarding.window.title")
        window.center()
        super.init(window: window)
        build()
        show(step: 0)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let window else { return }
        // The banner is the privacy promise, and it belongs here rather than
        // anywhere else in the app: it is the answer to the question the next
        // screen is about to ask for — permission to watch every keystroke.
        banner = NSImageView(image: NSImage(named: "Banner") ?? NSImage())
        banner.imageScaling = .scaleProportionallyUpOrDown
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 10
        banner.layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            banner.widthAnchor.constraint(equalToConstant: 456),
            banner.heightAnchor.constraint(equalToConstant: 214),
        ])

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

        let stack = NSStackView(views: [banner, title, body, NSView(), buttons])
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
        // Banner only on the welcome screen: it is a greeting, not a heading.
        banner.isHidden = stepIndex != 0
        if stepIndex == 1 { startWatchingForGrant() } else { poll?.invalidate() }
        window?.setContentSize(NSSize(width: 520, height: stepIndex == 0 ? 560 : 430))
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
            Settings.shared.hasSeenWelcome = true
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
        // Remembered before the timer exists, for the same reason as in
        // `AppDelegate`: a restart only helps when access arrived after this
        // process started. If we were already trusted and things still do not
        // work, restarting lands in the same place — and this window comes back
        // in front of whatever the person was doing, every time.
        let trustedAtStart = AXIsProcessTrusted()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }
            let last = UserDefaults.standard.double(forKey: AppDelegate.relaunchStampKey)
            let since = last == 0 ? .greatestFiniteMagnitude
                                  : Date().timeIntervalSince1970 - last
            switch PermissionRecovery.decide(trusted: true,
                                             trustedAtStart: trustedAtStart,
                                             tapStarted: false,
                                             alreadyRelaunched: false,
                                             secondsSinceLastRelaunch: since,
                                             elapsed: 1) {
            case .relaunch:
                poll?.invalidate()
                UserDefaults.standard.set(Date().timeIntervalSince1970,
                                          forKey: AppDelegate.relaunchStampKey)
                relaunch()
            case .stuck:
                // Nothing a restart can fix. Stop asking and leave the window
                // where it is; the step itself explains what to do.
                poll?.invalidate()
            case .granted, .keepWaiting, .giveUp:
                break
            }
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
