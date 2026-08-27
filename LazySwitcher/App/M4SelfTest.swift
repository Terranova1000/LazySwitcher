import AppKit
import ApplicationServices

/// Drives one real replacement into whatever field is focused, then reads the
/// field back to see whether it actually changed.
///
/// The point is the last step. Both replacement routes can report success and
/// change nothing — accessibility does it by design in browsers, synthetic
/// typing does it when an app ignores the unicode payload — so a self-test that
/// only checks return codes would pass while the product is broken. This one
/// reads the text back out.
///
/// Triggered by a file so it needs no clicking. Point it at
/// `Tools/eval/fixtures/text-field.html`, never at anything real.
/// M4 scaffolding; deleted once the compatibility table is filled in.
enum M4SelfTest {

    static var resultsURL: URL {
        M0Report.url.deletingLastPathComponent().appendingPathComponent("m4-selftest.txt")
    }
    private static var triggerURL: URL {
        M0Report.url.deletingLastPathComponent().appendingPathComponent("m4-selftest-run")
    }

    /// "ghbdtn" — g h b d t n as positions on the board.
    private static let privetKeyCodes: [UInt16] = [0x05, 0x04, 0x0B, 0x02, 0x11, 0x2D]

    static func watchForTrigger(delegate: AppDelegate) {
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            guard FileManager.default.fileExists(atPath: triggerURL.path) else { return }
            let target = (try? String(contentsOf: triggerURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: triggerURL)

            // Bring the target app forward ourselves. Whoever launched the test
            // is a terminal, and it takes focus back the moment its command
            // returns — measuring the wrong app every time.
            guard !target.isEmpty,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: target).first
            else { run(delegate: delegate); return }
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                delegate.refreshContextForSelfTest()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(delegate: delegate) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    static func run(delegate: AppDelegate) {
        var lines: [String] = ["# Самотест замены (M4)"]
        let app = NSWorkspace.shared.frontmostApplication
        lines.append("приложение: \(app?.localizedName ?? "—") (\(app?.bundleIdentifier ?? "—"))")

        let keys = privetKeyCodes.map { KeyRecord(keyCode: $0) }
        guard let reading = delegate.readingForSelfTest(keys: keys) else {
            lines.append("не удалось прочитать слово в двух раскладках")
            write(lines)
            return
        }
        lines.append("ожидаем: «\(reading.typed)» → «\(reading.alternative)»")

        // Fill the field first. Replacing into an empty field would send
        // backspaces at nothing and prove only that we can type — the whole
        // question is whether we delete exactly the right characters.
        guard let typist = SyntheticEventSource() else {
            lines.append("не удалось создать источник событий")
            write(lines)
            return
        }
        let sentinel = "xx"          // текст, который трогать нельзя
        DispatchQueue.global(qos: .userInitiated).async {
            typist.type(sentinel + reading.typed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let before = readFocusedText()
                lines.append("поле до:    «\(before ?? "?")»")
                lines.append("AX в момент: role=\(delegate.focus.lastRole) subrole=\(delegate.focus.lastSubrole) → \(delegate.context.current.fieldRole)")

                delegate.applyForSelfTest(keys: keys)

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    let after = readFocusedText()
                    lines.append("поле после: «\(after ?? "?")»")
                    lines.append("стратегия:  \(delegate.lastReplacementNote)")
                    lines.append("")
                    let expected = sentinel + reading.alternative
                    let role = delegate.context.current.fieldRole
                    if role == .secure || role == .terminal || role == .code {
                        // In these fields refusal is the correct outcome, so the
                        // check inverts: an unchanged field is the pass.
                        if after == before {
                            lines.append("РЕЗУЛЬТАТ: успех — поле типа «\(role)» не тронуто, как и должно быть")
                        } else {
                            lines.append("РЕЗУЛЬТАТ: ПРОВАЛ БЕЗОПАСНОСТИ — поле типа «\(role)» изменено")
                        }
                    } else if (before ?? "").isEmpty, (after ?? "").isEmpty {
                        // Chrome and Firefox never expose field text, so there is
                        // nothing to read back. Not a failure — an unverifiable
                        // case, and calling it a pass would be worse than saying so.
                        lines.append("РЕЗУЛЬТАТ: проверить нельзя — приложение не отдаёт текст поля.")
                        lines.append("           Смотреть глазами: в поле должно быть «\(expected)»")
                    } else if after == expected {
                        lines.append("РЕЗУЛЬТАТ: успех — заменено ровно нужное, «\(sentinel)» не тронут")
                    } else if after?.hasSuffix(reading.alternative) == true {
                        lines.append("РЕЗУЛЬТАТ: слово заменено, но соседний текст пострадал —")
                        lines.append("           ожидали «\(expected)», получили «\(after ?? "?")»")
                    } else {
                        lines.append("РЕЗУЛЬТАТ: провал — ожидали «\(expected)», получили «\(after ?? "?")»")
                    }
                    write(lines)
                }
            }
        }
    }

    private static func write(_ lines: [String]) {
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: resultsURL, atomically: true, encoding: .utf8)
    }

    /// Reads the focused field's text. Diagnostics only, and only ever pointed
    /// at our own fixture pages.
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
                                            &value) == .success
        else { return nil }
        return value as? String
    }
}
