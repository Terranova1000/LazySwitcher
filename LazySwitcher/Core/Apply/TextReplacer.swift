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
    private enum AccessibilityResult {
        case replaced
        case notSupported
        case mismatch
    }

    private let synthetic: SyntheticEventSource?
    var syntheticSource: SyntheticEventSource? { synthetic }
    /// Apps where the accessibility route claimed success and changed nothing.
    /// Once burned we do not try it there again this session.
    private var accessibilityFailures: Set<String> = []

    init(synthetic: SyntheticEventSource? = SyntheticEventSource()) {
        self.synthetic = synthetic
    }

    /// - Parameters:
    ///   - original: what is on screen now, exactly as typed.
    ///   - replacement: what should be there instead.
    ///   - bundleID: the frontmost app, for remembering what works where.
    @discardableResult
    func replace(original: String, with replacement: String, in bundleID: String) -> Outcome {
        if !accessibilityFailures.contains(bundleID) {
            switch replaceViaAccessibility(original: original, with: replacement) {
            case .replaced:
                return Outcome(strategy: .accessibility, succeeded: true)
            case .mismatch:
                // Refuse outright. The text is not what we believed it was, so
                // every fallback is a guess about somebody else's characters.
                return Outcome(strategy: .accessibility, succeeded: false)
            case .notSupported:
                accessibilityFailures.insert(bundleID)
            }
        }

        guard let synthetic else { return Outcome(strategy: .synthetic, succeeded: false) }
        // Count characters, not UTF-16 units: one backspace removes one glyph,
        // and counting units would over-delete anything outside the BMP.
        synthetic.replace(deleting: original.count, with: replacement)
        return Outcome(strategy: .synthetic, succeeded: true)
    }

    func forget(_ bundleID: String) { accessibilityFailures.remove(bundleID) }

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

        let length = (original as NSString).length
        // Not enough text in front of the caret to be what we think it is. The
        // app reports a position we cannot reconcile, so nobody should type here.
        guard caret.location >= length else { return .mismatch }

        // Select exactly the word, then write over the selection.
        //
        // Never kAXValueAttribute: rewriting the whole field destroys the app's
        // undo history, throws the caret back to the start, and bypasses any
        // validation the field does.
        var wordRange = CFRange(location: caret.location - length, length: length)
        guard let selection = AXValueCreate(.cfRange, &wordRange) else { return .notSupported }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                           selection) == .success
        else { return .notSupported }

        // Verify we actually selected what we meant to. Without this check a
        // stale caret position silently overwrites the wrong characters.
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &selectedValue) == .success,
              let selected = selectedValue as? String
        else { return .notSupported }
        // Selected something, but not what we meant to. Our model of the text is
        // wrong; stop here rather than fall through to counting backspaces.
        guard selected == original else { return .mismatch }

        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                           replacement as CFTypeRef) == .success
        else { return .notSupported }

        // "Success" from AX means the message was accepted, not that anything
        // changed — browsers in particular accept and ignore. Read it back.
        var afterValue: CFTypeRef?
        var afterRange = CFRange(location: wordRange.location, length: (replacement as NSString).length)
        guard let afterSelection = AXValueCreate(.cfRange, &afterRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                           afterSelection) == .success,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &afterValue) == .success,
              let after = afterValue as? String, after == replacement
        else { return .notSupported }

        // Collapse the selection so the caret sits after the word, as if typed.
        var collapsed = CFRange(location: afterRange.location + afterRange.length, length: 0)
        if let value = AXValueCreate(.cfRange, &collapsed) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
        return .replaced
    }

    private func focusedElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
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
