import AppKit
import ApplicationServices

/// Reading and replacing whatever the user has selected.
///
/// This is what makes "I typed a whole paragraph in the wrong layout" fixable:
/// select it, press the hotkey, done. Without it the only remedy is retyping,
/// which is the moment people give up on a tool like this.
enum TextSelection {

    struct Snapshot {
        let text: String
        let element: AXUIElement
    }

    /// The current selection, or nil if there is none we can see.
    ///
    /// Returns nil rather than guessing in browsers that hide their tree — the
    /// synthetic path can still replace a selection there by typing over it, but
    /// we would not know what we were replacing, and converting text we cannot
    /// read is exactly how a password gets mangled.
    static func current() -> Snapshot? {
        guard let pid = AppMonitor.trueFrontmost()?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let raw = focused
        else { return nil }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &selected) == .success,
              let text = selected as? String,
              !text.isEmpty
        else { return nil }

        return Snapshot(text: text, element: element)
    }

    /// Writes `replacement` over the selection.
    ///
    /// Accessibility first — one operation, the app's own undo survives. If that
    /// route reports success without changing anything, which browsers do,
    /// typing works instead: with a selection active the first character
    /// replaces it, so nothing outside can be harmed even if our idea of the
    /// text was wrong.
    static func replace(_ snapshot: Snapshot,
                        with replacement: String,
                        synthetic: SyntheticEventSource?) -> Bool {
        if AXUIElementSetAttributeValue(snapshot.element, kAXSelectedTextAttribute as CFString,
                                        replacement as CFTypeRef) == .success {
            var check: CFTypeRef?
            if AXUIElementCopyAttributeValue(snapshot.element, kAXSelectedTextAttribute as CFString,
                                             &check) == .success,
               let now = check as? String, now == replacement || now.isEmpty {
                return true
            }
        }
        guard let synthetic else { return false }
        synthetic.type(replacement)
        return true
    }
}
