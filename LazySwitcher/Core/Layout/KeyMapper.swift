import AppKit
import Carbon.HIToolbox
import CoreServices

/// Turns key codes into the characters a given keyboard layout would produce.
///
/// The idea the whole design rests on: `kTISPropertyUnicodeKeyLayoutData` is
/// readable for **any installed layout, not only the active one**. So we can ask
/// "what would the Russian layout have made of these keys" while English is
/// active, and never touch the user's input source to find out.
///
/// Everything comes from the system. There is no table of letters in this file,
/// which is what makes odd layouts (Russian — PC, Dvorak, ISO boards) work by
/// construction rather than by luck.
final class KeyMapper {

    /// One layout's key-code → character table, built once and reused.
    struct Table {
        let layoutID: String
        /// Indexed by `index(keyCode:shift:option:)`. nil = key produces nothing here.
        fileprivate let entries: [String?]
        fileprivate let reverse: [Character: (keyCode: UInt16, shift: Bool, option: Bool)]

        func character(keyCode: UInt16, shift: Bool, option: Bool = false) -> String? {
            let i = Table.index(keyCode: keyCode, shift: shift, option: option)
            guard i < entries.count else { return nil }
            return entries[i]
        }

        /// Character → the keystroke that produces it in this layout.
        ///
        /// Needed to convert text we did not watch being typed — a selection the
        /// user made with the mouse, for instance. Where several keys produce the
        /// same character the lowest key code wins, and unshifted beats shifted,
        /// so the result is stable rather than dependent on iteration order.
        func keystroke(for character: Character) -> (keyCode: UInt16, shift: Bool, option: Bool)? {
            reverse[character]
        }

        /// Did this table actually come out of a keyboard layout?
        ///
        /// A real layout fills well over a hundred slots. A handful means the
        /// layout data was not readable at the moment we asked — it happens
        /// right after launch and just after a layout is activated — and every
        /// word rendered through such a table comes out as nothing, so every
        /// word is refused for what look like good reasons.
        ///
        /// Worth checking because the answer used to be cached. One bad moment
        /// poisoned that layout for the rest of the session, and the only thing
        /// that cleared it was switching the language by hand: exactly the
        /// "it does not work until I switch the language once" report.
        var isUsable: Bool {
            guard !reverse.isEmpty else { return false }
            return entries.reduce(0) { $1 == nil ? $0 : $0 + 1 } >= 40
        }

        fileprivate static func index(keyCode: UInt16, shift: Bool, option: Bool) -> Int {
            Int(keyCode) * 4 + (shift ? 1 : 0) + (option ? 2 : 0)
        }
        fileprivate static let keyCodeCount = 128
        fileprivate static let slotCount = keyCodeCount * 4
    }

    private var cache: [String: Table] = [:]

    // MARK: - Public

    /// - Important: main thread only. It reads TIS properties, which trap when
    ///   called from anywhere else (see `InputSourceService`).
    func table(for source: TISInputSource) -> Table? {
        guard let id = InputSourceService.identifier(of: source) else { return nil }
        if let cached = cache[id] { return cached }
        guard let built = Self.buildTable(for: source, id: id) else { return nil }
        // Only remember an answer worth remembering. Caching an empty table made
        // one unlucky moment permanent; refusing to cache it costs a rebuild and
        // lets the next attempt succeed.
        guard built.isUsable else {
            unusableTables += 1
            return nil
        }
        cache[id] = built
        return built
    }

    /// Diagnostic: how many times a layout answered with nothing usable.
    private(set) var unusableTables = 0

    func invalidate() { cache.removeAll() }

    /// Reads existing text back into the keystrokes that produced it.
    ///
    /// Returns nil if any character has no key in this layout — a partial answer
    /// would silently drop characters from the middle of the user's sentence.
    func keystrokes(of text: String, in table: Table) -> [KeyRecord]? {
        var keys: [KeyRecord] = []
        keys.reserveCapacity(text.count)
        for character in text {
            guard let stroke = table.keystroke(for: character) else { return nil }
            keys.append(KeyRecord(keyCode: stroke.keyCode, shift: stroke.shift, option: stroke.option))
        }
        return keys
    }

    /// Renders a run of keystrokes as the given layout would have produced it.
    /// Returns nil if any key has no character there — a partial string would be
    /// worse than none, because we would then delete the wrong number of glyphs.
    func render(_ keys: [KeyRecord], with table: Table) -> String? {
        var out = ""
        out.reserveCapacity(keys.count)
        for key in keys {
            // Caps Lock inverts Shift, but only for letters: it turns `a` into
            // `A` and leaves `,` alone. So the decision is made per key, from
            // what that key produces unshifted, rather than once for the word.
            var shift = key.shift
            if key.capsLock,
               let plain = table.character(keyCode: key.keyCode, shift: false, option: key.option),
               plain.first?.isLetter == true {
                shift.toggle()
            }
            guard let ch = table.character(keyCode: key.keyCode, shift: shift, option: key.option) else {
                return nil
            }
            out += ch
        }
        return out
    }

    // MARK: - Building

    private static func buildTable(for source: TISInputSource, id: String) -> Table? {
        // Documented to be NULL for input methods that are not keyboard layouts
        // (the CJK ones). That is a signal to stand down, not to guess.
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())

        var entries = [String?](repeating: nil, count: Table.slotCount)

        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)

            for keyCode in 0..<UInt16(Table.keyCodeCount) {
                for (shift, option) in [(false, false), (true, false), (false, true), (true, true)] {
                    var carbonModifiers: UInt32 = 0
                    if shift { carbonModifiers |= UInt32(shiftKey) }
                    if option { carbonModifiers |= UInt32(optionKey) }
                    // UCKeyTranslate wants the *high byte* of the Carbon modifier
                    // word. Forgetting this shift is the classic way to get a
                    // table where Shift does nothing.
                    let modifierState = (carbonModifiers >> 8) & 0xFF

                    if let ch = translate(layout: layout, keyCode: keyCode,
                                          modifierState: modifierState, keyboardType: keyboardType) {
                        entries[Table.index(keyCode: keyCode, shift: shift, option: option)] = ch
                    }
                }
            }
        }

        // Build the reverse map in a fixed order so ties resolve the same way
        // every time: lowest key code first, unshifted before shifted, and no
        // Option variants at all — those are typographic extras (± § ≈), not the
        // characters people mean when they mistype a layout.
        var reverse: [Character: (keyCode: UInt16, shift: Bool, option: Bool)] = [:]
        for keyCode in 0..<UInt16(Table.keyCodeCount) {
            for shift in [false, true] {
                let slot = Table.index(keyCode: keyCode, shift: shift, option: false)
                guard let text = entries[slot], text.count == 1, let character = text.first else { continue }
                if reverse[character] == nil {
                    reverse[character] = (keyCode, shift, false)
                }
            }
        }

        return Table(layoutID: id, entries: entries, reverse: reverse)
    }

    private static func translate(layout: UnsafePointer<UCKeyboardLayout>,
                                  keyCode: UInt16,
                                  modifierState: UInt32,
                                  keyboardType: UInt32) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        // Int, not UniCharCount: Swift imports the C `unsigned long` length
        // parameters as Int, and UniCharCount is not surfaced as a type at all.
        var length = 0

        // options = 0 means dead keys ARE processed.
        //
        // Do not "fix" this to kUCKeyTranslateNoDeadKeysBit: that constant is the
        // bit *number*, and it equals 0, so passing it disables nothing. The mask
        // is kUCKeyTranslateNoDeadKeysMask == 1. The widely copied code in
        // node-native-keymap passes the Bit and works only by accident. We pass 0
        // deliberately and handle dead keys with the second call below.
        var status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown),
                                    modifierState, keyboardType, OptionBits(0),
                                    &deadKeyState, chars.count, &length, &chars)

        // A dead key swallows the first call and yields nothing; calling again
        // with the state it set produces the standalone character.
        if status == noErr, length == 0, deadKeyState != 0 {
            status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown),
                                    modifierState, keyboardType, OptionBits(0),
                                    &deadKeyState, chars.count, &length, &chars)
        }

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
