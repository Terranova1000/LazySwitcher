import Carbon.HIToolbox
import CoreGraphics
import Darwin

/// The one place in the project that posts keyboard events.
///
/// Three settings here are not stylistic, and getting any of them wrong produces
/// a bug that looks like something else entirely:
///
/// · `.privateState` rather than `.combinedSessionState` — a private source keeps
///   its own modifier state. Share the session's and a synthetic Shift leaks into
///   the user's real typing, leaving them with a stuck modifier.
/// · `localEventsSuppressionInterval = 0` — the default makes macOS mute the
///   user's actual keyboard for a quarter second after each event we post.
/// · `userData` marker — our own events come straight back through our tap, and
///   without a way to recognise them the corrections we type get corrected again.
final class SyntheticEventSource {

    /// "LZSW". Matched in the tap callback's first line.
    static let marker = KeyTapService.syntheticMarker

    private let source: CGEventSource

    /// Milliseconds between events. Empirically 2–4 ms is the floor; espanso
    /// ships 10 ms by default for the same reason. Per-app tuning belongs in
    /// settings once the compatibility table says which apps need it.
    var backspaceDelay: useconds_t = 3_000
    var typingDelay: useconds_t = 4_000
    /// Many apps process text asynchronously, so the first backspace must not
    /// arrive on the heels of the keystroke that triggered us. `TextReplacer`
    /// waits for that already, so this is only the margin on top.
    var leadInDelay: useconds_t = 8_000

    init?() {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = Self.marker
        source.localEventsSuppressionInterval = 0
        self.source = source
    }

    // MARK: - Posting

    private static let backspaceKeyCode: CGKeyCode = 0x33

    func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        // Long runs need more room between events.
        //
        // Measured: fourteen backspaces at three milliseconds lost one of them,
        // and the loss is silent — the replacement then lands one character
        // short and the survivor sits at the front of the word, which is exactly
        // what «ппривет» is. Seven at the same spacing were fine. Applications
        // drop what they cannot keep up with, and the longer the burst the more
        // likely that becomes, so the spacing grows with the run.
        let spacing = count > 8 ? backspaceDelay * 2 : backspaceDelay
        for _ in 0..<count {
            post(virtualKey: Self.backspaceKeyCode, keyDown: true)
            post(virtualKey: Self.backspaceKeyCode, keyDown: false)
            usleep(spacing)
        }
    }

    func type(_ text: String) {
        for chunk in Self.chunks(of: text) {
            postUnicode(chunk)
            usleep(typingDelay)
        }
    }

    /// Deletes `count` characters and types `text` in their place.
    func replace(deleting count: Int, with text: String) {
        usleep(leadInDelay)
        sendBackspaces(count)
        type(text)
    }

    // MARK: - Building events

    private func post(virtualKey: CGKeyCode, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown)
        else { return }
        // Explicitly empty: if the user is holding Shift when we fire, an
        // inherited modifier turns our backspace into something else.
        event.flags = []
        event.post(tap: .cgSessionEventTap)
    }

    private func postUnicode(_ units: [UniChar]) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }
        down.flags = []
        up.flags = []
        // The payload goes on the key-down only.
        //
        // Putting it on the key-up as well is the common recipe and it is wrong
        // for the same reason a doubled keystroke is wrong: an application that
        // inserts text on both events inserts it twice. That is where the
        // duplicated word came from — two replacements produced three copies,
        // and the arithmetic never worked out until this was the explanation
        // left standing.
        //
        // The key-up is still posted, with no payload: applications track key
        // state, and a down without an up leaves them believing a key is held.
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Splits on **character** boundaries, not on a fixed count of UTF-16 units.
    ///
    /// Cutting by units can land in the middle of a surrogate pair or between a
    /// letter and its combining mark, and what arrives is then a replacement
    /// glyph rather than the text. Irrelevant for Russian and English; very
    /// relevant the moment anyone adds a language with combining marks, and by
    /// then the bug would be far from this file.
    static func chunks(of text: String, maxUnits: Int = 20) -> [[UniChar]] {
        var result: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxUnits {
                result.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
