import AppKit
import ApplicationServices
import CoreGraphics

/// End-to-end check of automatic correction: types like a person would and sees
/// whether the text fixes itself.
///
/// The events here carry **no marker**, unlike everything else this app posts.
/// That is the entire point — marked events are discarded in the first line of
/// the tap callback, so a test using them would exercise the replacement code
/// while skipping the part that decides. These go through the tap, the word
/// buffer, the veto and the scorer exactly as real typing does.
///
/// M5 scaffolding. Deleted once the soak week starts, because an app that can
/// synthesise unmarked keystrokes on request is not something to ship.
enum M5SelfTest {

    static var resultsURL: URL {
        M0Report.url.deletingLastPathComponent().appendingPathComponent("m5-selftest.txt")
    }
    private static var triggerURL: URL {
        M0Report.url.deletingLastPathComponent().appendingPathComponent("m5-selftest-run")
    }

    /// "ghbdtn" then space. Six letters clears the five-character floor for
    /// automatic replacement, and the space is what commits the word.
    private static let sequence: [CGKeyCode] = [0x05, 0x04, 0x0B, 0x02, 0x11, 0x2D, 0x31]

    static func watchForTrigger(delegate: AppDelegate) {
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            guard FileManager.default.fileExists(atPath: triggerURL.path) else { return }
            let target = (try? String(contentsOf: triggerURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: triggerURL)
            guard !target.isEmpty,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: target).first
            else { return }
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                delegate.refreshContextForSelfTest()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(delegate: delegate) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    static func run(delegate: AppDelegate) {
        var lines = ["# Самотест автозамены (M5)"]
        let app = NSWorkspace.shared.frontmostApplication
        lines.append("приложение: \(app?.localizedName ?? "—")")
        lines.append("политика:   \(delegate.context.current.policy), поле: \(delegate.context.current.fieldRole)")

        let before = delegate.automaticReplacements.value

        // A source with no userData, so our own tap treats these as real keys.
        guard let source = CGEventSource(stateID: .privateState) else {
            lines.append("не удалось создать источник"); write(lines); return
        }
        source.localEventsSuppressionInterval = 0

        DispatchQueue.global(qos: .userInitiated).async {
            for key in sequence {
                for down in [true, false] {
                    if let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) {
                        event.flags = []
                        event.post(tap: .cgSessionEventTap)
                    }
                }
                usleep(60_000)          // как человек, а не как автомат
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let text = readFocusedText()
                lines.append("в поле:     «\(text ?? "прочитать не удалось")»")
                lines.append("решение:    \(delegate.lastDecisionNote)")
                lines.append("действие:   \(delegate.lastReplacementNote)")
                lines.append("автозамен:  \(before) → \(delegate.automaticReplacements.value)")
                lines.append("")
                if let text, text.contains("привет") {
                    lines.append("РЕЗУЛЬТАТ: успех — набрали ghbdtn, в поле «привет»")
                } else if let text, text.contains("ghbdtn") {
                    lines.append("РЕЗУЛЬТАТ: не сработало — текст остался латиницей")
                } else {
                    lines.append("РЕЗУЛЬТАТ: неясно — поле прочитать не удалось")
                }
                write(lines)
            }
        }
    }

    private static func write(_ lines: [String]) {
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: resultsURL, atomically: true, encoding: .utf8)
    }

    private static func readFocusedText() -> String? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let element = focused
        else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString,
                                            &value) == .success else { return nil }
        return value as? String
    }
}
