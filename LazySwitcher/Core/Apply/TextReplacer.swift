import AppKit
import ApplicationServices

/// Swaps a word the user has already typed for its other-layout reading.
///
/// Two ways of doing it, and the choice is per app rather than global:
///
/// · **Accessibility** — set the selected range, then the selected text. One
///   operation, instant, keeps the app's own undo intact. Works in native
///   AppKit fields and nowhere else. Its failure mode is the nastiest kind:
///   it returns success and does nothing at all, so the result is verified.
/// · **Synthetic typing** — backspaces followed by the replacement. Works
///   nearly everywhere, but it is N events with pauses between them, and some
///   apps race it with their own autocomplete.
///
/// Deliberately absent: the pasteboard. It works almost everywhere, and users
/// hate it — it pollutes clipboard history, syncs to the iPhone via Universal
/// Clipboard, and needs a fragile delay to restore. "Never touches your
/// clipboard" is a feature worth keeping.
final class TextReplacer {

    enum Strategy: String {
        case accessibility
        case synthetic
    }

    struct Outcome {
        let strategy: Strategy
        let succeeded: Bool
    }

    /// What the accessibility route concluded.
    ///
    /// The distinction between the last two is the whole point. "This app does
    /// not support it" means try something else. "I selected a range and it did
    /// not contain what I expected" means our idea of where the caret is, is
    /// wrong — and the fallback deletes a fixed number of characters *at the
    /// caret*. Treating the second as the first is how a correction eats a
    /// neighbouring word.
    private enum AccessibilityResult: Equatable {
        case replaced
        case notSupported
        case mismatch
    }

    private let synthetic: SyntheticEventSource?
    var syntheticSource: SyntheticEventSource? { synthetic }

    /// Last few replacements: strategy, lengths, verdict. Lengths only — no
    /// text, ever (rule 1). Kept because the one thing that made the duplicated
    /// word tractable was seeing «ax:mismatch 7→7 | synth 14→14» written down;
    /// every hypothesis before that was guesswork.
    private(set) var history: [String] = []
    func clearHistory() { history.removeAll() }
    /// Why the last accessibility attempt gave up. Diagnostics only.
    private(set) var lastAXReason = "—"
    private func log(_ line: String) {
        history.append(line)
        if history.count > 12 { history.removeFirst() }
    }

    /// How long to let the app finish processing the keystroke that triggered
    /// us before looking at the text.
    ///
    /// We act on the space that ends a word, and many apps render it a frame or
    /// two later — so a query made immediately sees the text without that space,
    /// concludes the caret is one character short of where we expect, and calls
    /// it a mismatch. The synthetic route already waited for this reason; the
    /// accessibility route did not, and it read a field that had not caught up.
    var settleDelay: useconds_t = 25_000
    /// Apps where the accessibility route claimed success and changed nothing.
    /// Once burned we do not try it there again this session.
    /// Applications the accessibility route has failed in, and when.
    ///
    /// Timed rather than permanent. The entry used to be forever — `forget` was
    /// written for this and never called from anywhere — so one failure in an
    /// application meant every later replacement there went through synthetic
    /// typing, which sends a count of backspaces and cannot check what it is
    /// deleting. A single wrong guess about the text thus removed the one path
    /// that verifies itself, for the rest of the session.
    ///
    /// Applications also get better with time rather than worse: an accessibility
    /// tree that was not built when we first asked usually is later (Н35), so an
    /// answer from thirty seconds ago should not decide the next hour.
    private var accessibilityFailures: [String: Date] = [:]
    private static let failureMemory: TimeInterval = 60

    private func isBlacklisted(_ bundleID: String) -> Bool {
        guard let since = accessibilityFailures[bundleID] else { return false }
        guard Date().timeIntervalSince(since) < Self.failureMemory else {
            accessibilityFailures.removeValue(forKey: bundleID)
            return false
        }
        return true
    }

    init(synthetic: SyntheticEventSource? = SyntheticEventSource()) {
        self.synthetic = synthetic
    }

    /// - Parameters:
    ///   - original: what is on screen now, exactly as typed.
    ///   - replacement: what should be there instead.
    ///   - bundleID: the frontmost app, for remembering what works where.
    @discardableResult
    func replace(original: String, with replacement: String, in bundleID: String) -> Outcome {
        usleep(settleDelay)

        if !isBlacklisted(bundleID) {
            var result = replaceViaAccessibility(original: original, with: replacement)
            if result == .mismatch {
                // Give it one more chance before concluding anything. A slow
                // app and a genuinely wrong idea of the text look identical
                // from one query, and treating a slow app as a broken one costs
                // that app the fast route forever.
                usleep(60_000)
                result = replaceViaAccessibility(original: original, with: replacement)
            }
            log("ax:\(result)[\(lastAXReason)] \(original.count)→\(replacement.count)")
            switch result {
            case .replaced:
                return Outcome(strategy: .accessibility, succeeded: true)
            case .mismatch:
                // The app answered, but not with what we expected. Two things
                // look like this: our picture of the text is stale, or the app
                // counts ranges differently than we do — Electron and web views
                // are prone to the second.
                //
                // We cannot tell which from here, so we do neither: skip this
                // word, and stop trusting the accessibility route in this app.
                // The next word goes through synthetic typing, which does not
                // depend on the app agreeing with us about positions. One word
                // is lost per app, once, and then it works.
                accessibilityFailures[bundleID] = Date()
                return Outcome(strategy: .accessibility, succeeded: false)
            case .notSupported:
                accessibilityFailures[bundleID] = Date()
            }
        }

        guard let synthetic else { return Outcome(strategy: .synthetic, succeeded: false) }
        awaitRendered((original as NSString).length)
        // Count characters, not UTF-16 units: one backspace removes one glyph,
        // and counting units would over-delete anything outside the BMP.
        log("synth \(original.count)→\(replacement.count)")
        synthetic.replace(deleting: original.count, with: replacement)
        return Outcome(strategy: .synthetic, succeeded: true)
    }

    func forget(_ bundleID: String) { accessibilityFailures.removeValue(forKey: bundleID) }

    /// Whether the route that checks itself is expected to work here.
    ///
    /// Callers use this to decide how much text they are willing to rewrite at
    /// once. The synthetic route deletes by counting and cannot look at what it
    /// is deleting, so a run spanning several words there is several times the
    /// damage when our idea of the text is wrong.
    func hasVerifiedRoute(in bundleID: String) -> Bool { !isBlacklisted(bundleID) }

    /// Waits for the text we are about to delete backwards over to be on screen.
    ///
    /// The synthetic route sends a count of backspaces and trusts that many
    /// characters are there. We act on the space that ends a word, and an
    /// application that has not finished inserting that space yet leaves the
    /// caret one position short — so the count runs one past the word and takes
    /// the space before it. Typing `ghbdtn` then `руддщ` came out as
    /// «Приветhello»: the space between them was eaten and the user's own space
    /// arrived afterwards.
    ///
    /// macOS autocorrection makes this worse rather than causing it: it also
    /// fires on the space that ends a word, and rewrites text underneath us at
    /// exactly the moment we are measuring it.
    ///
    /// The caret position can be read in many applications where the text itself
    /// cannot, so this often confirms the length even where the verified route
    /// was unavailable. Where nothing can be read, a slightly longer wait is all
    /// that is left — better than measuring against text that is not there yet.
    private func awaitRendered(_ length: Int) {
        guard length > 0, let element = focusedElement() else { usleep(blindSettleDelay); return }
        for _ in 0..<4 {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                                &raw) == .success,
                  let value = raw, CFGetTypeID(value) == AXValueGetTypeID()
            else { usleep(blindSettleDelay); return }
            var caret = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &caret) else {
                usleep(blindSettleDelay); return
            }
            if caret.location >= length { return }
            usleep(15_000)
        }
    }

    /// Extra wait before deleting text we could not measure. Short enough to be
    /// invisible, long enough for an application to finish drawing a space.
    private let blindSettleDelay: UInt32 = 35_000

    // MARK: - Accessibility route

    private func replaceViaAccessibility(original: String,
                                         with replacement: String) -> AccessibilityResult {
        guard let element = focusedElement() else { return .notSupported }

        // Where the caret is, so we can walk back over the word.
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &rangeValue) == .success,
              let axRange = rangeValue, CFGetTypeID(axRange) == AXValueGetTypeID()
        else { return .notSupported }

        var caret = CFRange()
        guard AXValueGetValue(axRange as! AXValue, .cfRange, &caret) else { return .notSupported }
        let originalCaret = caret

        /// Puts the caret back before giving up.
        ///
        /// Every early exit past this point has already changed the selection,
        /// and leaving it changed is not a cosmetic problem: the user sees their
        /// word highlighted and nothing else happen, and their next keystroke
        /// replaces the highlighted word instead of continuing the sentence.
        /// This was reported as "the words just get selected and that is all",
        /// and it was correct.
        func giveUp(_ result: AccessibilityResult, _ why: String) -> AccessibilityResult {
            lastAXReason = why
            var restore = originalCaret
            if let value = AXValueCreate(.cfRange, &restore) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            return result
        }

        var length = (original as NSString).length

        // Not enough text in front of the caret. Usually this is not a wrong
        // idea of the text but a slow one: we act on the space that ends a word,
        // and the application has not finished inserting it, so the caret sits
        // one character short of where it will be a moment from now.
        //
        // Worth waiting for rather than giving up on. Giving up meant the word
        // was left alone, and then the next word's chain rebuilt both of them in
        // one long run of backspaces — which is where the duplicated letter came
        // from. One short wait here removes the cause instead of the symptom.
        if caret.location < length {
            usleep(30_000)
            var retryValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                                &retryValue) == .success,
                  let retryRange = retryValue, CFGetTypeID(retryRange) == AXValueGetTypeID(),
                  AXValueGetValue(retryRange as! AXValue, .cfRange, &caret),
                  caret.location >= length
            else { lastAXReason = "каретка на \(caret.location), нужно \(length)"; return .mismatch }
        }
        _ = length
        length = (original as NSString).length

        // Select exactly the word, then write over the selection.
        //
        // Never kAXValueAttribute: rewriting the whole field destroys the app's
        // undo history, throws the caret back to the start, and bypasses any
        // validation the field does.
        var wordRange = CFRange(location: caret.location - length, length: length)
        guard let selection = AXValueCreate(.cfRange, &wordRange) else { return .notSupported }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                           selection) == .success
        else { return giveUp(.notSupported, "нет поддержки") }

        // Verify we actually selected what we meant to. Without this a stale
        // caret position silently overwrites the wrong characters.
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &selectedValue) == .success,
              let selected = selectedValue as? String
        else { return giveUp(.notSupported, "нет поддержки") }
        guard selected == original else { return giveUp(.mismatch, "выделилось не то: \(selected.count) симв. вместо \(original.count)") }

        // The last point at which nothing has been written yet. A failure here
        // is genuinely "this app does not support it", and falling through to
        // synthetic typing is correct.
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                           replacement as CFTypeRef) == .success
        else { return giveUp(.notSupported, "нет поддержки") }

        // Past this line the text has been written. Whatever happens next, the
        // one thing we must not report is `.notSupported` — that sends the
        // caller on to the synthetic route, which deletes and types **again**.
        //
        // That is where the duplicated word came from: two replacements of seven
        // characters on a field of fourteen produced twenty-one. The read-back
        // below failed, we called it "not supported", and the fallback typed the
        // word a second time on top of the one already there.
        //
        // "Success" from AX means the message was accepted, not that anything
        // changed — browsers in particular accept and ignore — so the read-back
        // stays. Only its failure verdict changes: `.mismatch`, which stops
        // everything, rather than `.notSupported`, which starts something else.
        var afterValue: CFTypeRef?
        var afterRange = CFRange(location: wordRange.location, length: (replacement as NSString).length)
        guard let afterSelection = AXValueCreate(.cfRange, &afterRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                           afterSelection) == .success,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &afterValue) == .success,
              let after = afterValue as? String
        else { return giveUp(.mismatch, "не прочиталось после записи") }

        // Read back what we asked for: the write worked, the app simply has not
        // told us so in a way we can confirm. Treat it as done rather than doing
        // it twice.
        guard after == replacement else { return giveUp(.mismatch, "после записи не то: \(after.count) вместо \(replacement.count)") }

        // Collapse the selection so the caret sits after the word, as if typed.
        var collapsed = CFRange(location: afterRange.location + afterRange.length, length: 0)
        if let value = AXValueCreate(.cfRange, &collapsed) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
        return .replaced
    }

    /// The process to write into. Kept in step with the focus monitor so that
    /// the decision and the write cannot land in different applications.
    var targetPID: pid_t = 0

    private func focusedElement() -> AXUIElement? {
        let resolved = targetPID != 0 ? targetPID : AppMonitor.trueFrontmost()?.processIdentifier
        guard let pid = resolved else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused
        else { return nil }
        let target = element as! AXUIElement
        AXUIElementSetMessagingTimeout(target, 0.2)
        return target
    }
}
