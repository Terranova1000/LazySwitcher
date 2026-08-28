import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

// ВЕСЬ ЭТОТ ФАЙЛ — ТОЛЬКО ДЛЯ ОТЛАДКИ.
//
// Леса вокруг разработки: они запускаются по появлению файла-триггера в
// ~/Library/Application Support/Lazy Switcher/, а часть из них умеет
// синтезировать нажатия клавиш. В приложении с доступом Accessibility это
// означает, что любой, кто способен записать файл в домашнюю папку, может
// заставить программу печатать. Для отладки — необходимый инструмент, в
// готовом продукте — вектор атаки, которого не должно существовать.
//
// Поэтому весь файл вырезается из Release на этапе компиляции: не «выключен
// флагом», не «спрятан за настройкой», а физически отсутствует в бинарнике.
#if DEBUG

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
    private static let defaultSequence: [CGKeyCode] = [0x05, 0x04, 0x0B, 0x02, 0x11, 0x2D, 0x31]
    /// Overridden from the trigger file: "bundleID 05,04,25,25,1F,31" (hex).
    private static var sequence: [CGKeyCode] = defaultSequence
    private static var expected = "привет"
    /// Language the test wants active before it types.
    private static var startLanguage = "en"
    private static var pressHotkey = false

    static func watchForTrigger(delegate: AppDelegate) {
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            guard FileManager.default.fileExists(atPath: triggerURL.path) else { return }
            let raw = (try? String(contentsOf: triggerURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: triggerURL)
            let parts = raw.split(separator: " ", maxSplits: 2).map(String.init)
            let target = parts.first ?? ""
            if parts.count > 1 {
                let codes = parts[1].split(separator: ",").compactMap { CGKeyCode($0, radix: 16) }
                sequence = codes.isEmpty ? defaultSequence : codes
            } else {
                sequence = defaultSequence
            }
            expected = parts.count > 2 ? parts[2] : "привет"
            // Хвост «+hotkey» — нажать жест после набора, а не ждать автозамены.
            pressHotkey = raw.contains("+hotkey")
            // Format: "bundleID lang:codes expected", lang optional.
            if let colon = parts.count > 1 ? parts[1].firstIndex(of: ":") : nil {
                startLanguage = String(parts[1][parts[1].startIndex..<colon])
                let rest = parts[1][parts[1].index(after: colon)...]
                let codes = rest.split(separator: ",").compactMap { CGKeyCode($0, radix: 16) }
                if !codes.isEmpty { sequence = codes }
            }
            intendedTarget = target
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

    /// Set by the trigger; the test refuses to type anywhere else.
    private static var intendedTarget = ""

    static func run(delegate: AppDelegate) {
        var lines = ["# Самотест автозамены (M5)"]
        let app = NSWorkspace.shared.frontmostApplication
        lines.append("приложение: \(app?.localizedName ?? "—")")

        // Refuse if the app we meant to test is not the one in front.
        //
        // Learned the hard way: activation does not always win, and the test
        // then types into whatever is focused — which once meant appending a
        // word to a message somebody was composing. A test rig that synthesises
        // keystrokes has to be certain where they will land, and "probably the
        // right app" is not certain.
        // Put the requested layout in force first. Which layout is active
        // decides what the keystrokes mean, so a test that does not set it is
        // measuring whatever the previous test left behind.
        if let wanted = InputSourceService.enabledKeyboardLayouts().first(where: {
            InputSourceService.primaryLanguage(of: $0) == startLanguage
        }), InputSourceService.primaryLanguage(of: InputSourceService.currentLayout()!) != startLanguage {
            TISSelectInputSource(wanted)
            Thread.sleep(forTimeInterval: 0.4)
        }

        guard app?.bundleIdentifier == intendedTarget else {
            lines.append("ОТКАЗ: впереди не «\(intendedTarget)», печатать не будем")
            write(lines)
            return
        }
        lines.append("политика:   \(delegate.context.current.policy), поле: \(delegate.context.current.fieldRole)")
        if let current = InputSourceService.currentLayout() {
            lines.append("раскладка:  \(InputSourceService.localizedName(of: current) ?? "—") "
                       + "(\(InputSourceService.primaryLanguage(of: current) ?? "?"))")
        }

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

            if pressHotkey {
                // Тот же путь, что у настоящего жеста, без синтеза модификаторов:
                // Secure Input и прочие условия проверяются внутри.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    delegate.triggerHotkeyForSelfTest()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                let text = readFocusedText()
                lines.append("в поле:     «\(text ?? "прочитать не удалось")»")
                lines.append("решение:    \(delegate.lastDecisionNote)")
                lines.append("действие:   \(delegate.lastReplacementNote)")
                lines.append("автозамен:  \(before) → \(delegate.automaticReplacements.value)")
                if let now = InputSourceService.currentLayout() {
                    lines.append("раскладка после: \(InputSourceService.localizedName(of: now) ?? "—") "
                               + "(\(InputSourceService.primaryLanguage(of: now) ?? "?"))")
                }
                lines.append("")
                lines.append("ожидали:    «\(expected)»")
                if let text, text.contains(expected) {
                    lines.append("РЕЗУЛЬТАТ: успех")
                } else if text != nil {
                    lines.append("РЕЗУЛЬТАТ: не сработало")
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
#endif
