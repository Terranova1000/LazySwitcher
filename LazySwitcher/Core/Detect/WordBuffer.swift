import Carbon.HIToolbox
import Darwin

/// The last few keystrokes, as positions on the keyboard.
///
/// Fixed capacity, allocated once, never grows: the event-tap thread appends to
/// it and must not allocate (CLAUDE.md rule 7). `wipe()` overwrites the storage
/// with `memset_s` rather than reassigning, so the bytes are actually gone and
/// not merely unreferenced.
///
/// It stores key codes and knows nothing about letters. Word boundaries are only
/// the ones that mean the same thing in every layout — space, tab, return. It
/// deliberately does NOT treat `.` `,` `;` `'` `[` `]` as boundaries, because on
/// ЙЦУКЕН those keys are the letters ю б ж э х ъ, and cutting words there would
/// destroy roughly a third of Russian words before scoring ever sees them.
/// Deciding whether such a key ended a word needs the layout tables, and that
/// happens later, off this thread.
final class WordBuffer {

    static let capacity = 64

    private let storage: UnsafeMutableBufferPointer<KeyRecord>
    private var count = 0

    /// Why the buffer was last cleared. Useful in diagnostics, never persisted.
    private(set) var lastResetReason: ResetReason = .initial

    /// The word that was just finished, and the key that finished it.
    ///
    /// Kept so the hotkey can still reach the word after the user has typed the
    /// space — which is when people actually notice the layout was wrong.
    ///
    /// Valid **only until the very next event of any kind**. That narrowness is
    /// the whole point: this is a promise about where the caret is, and the
    /// moment anything else happens — another key, a click, a focus change — the
    /// promise is void. An earlier version kept it for thirty seconds by the
    /// clock instead, and would then delete that many characters wherever the
    /// caret happened to be by then, eating a neighbouring word.
    private(set) var justCommitted: (keys: [KeyRecord], terminator: UInt16)?

    enum ResetReason {
        case initial, secureInput, focusChanged, appChanged, modifierChord
        case caretMoved, mouseClick, idleTimeout, wordCommitted, replacementApplied
    }

    init() {
        storage = UnsafeMutableBufferPointer<KeyRecord>.allocate(capacity: Self.capacity)
        storage.initialize(repeating: KeyRecord(keyCode: 0))
    }

    deinit {
        wipe(reason: .initial)
        storage.deallocate()
    }

    // MARK: - Reading

    var isEmpty: Bool { count == 0 }
    var keyCount: Int { count }

    /// The run of keystrokes since the last boundary or reset.
    var currentWord: [KeyRecord] { Array(storage[0..<count]) }

    // MARK: - Writing

    enum AppendResult: Equatable {
        /// Ordinary character key; the word grew.
        case extended
        /// Space, tab or return: the word just ended, and here it is together
        /// with the key that ended it — a later hotkey has to delete that key
        /// too, and retype it, to leave the text as the user meant it.
        case boundary(word: [KeyRecord], terminator: UInt16)
        /// Backspace took the last key back off.
        case retracted
        /// Something that invalidates our picture of the text.
        case reset(ResetReason)
        /// Not a key we track at all.
        case ignored
    }

    func append(_ record: KeyRecord, hasCommandControlOrOption: Bool) -> AppendResult {
        // Anything at all happening invalidates the just-committed word: the
        // caret is no longer immediately after it.
        let carriedOver = justCommitted
        justCommitted = nil
        _ = carriedOver

        // A chord means the keystroke did something other than type a letter, and
        // whatever it did we can no longer trust our model of the text.
        if hasCommandControlOrOption {
            wipe(reason: .modifierChord)
            return .reset(.modifierChord)
        }

        if Self.caretMovingKeyCodes.contains(record.keyCode) {
            // The caret is no longer where we think it is, so our backspaces
            // would delete the wrong characters.
            wipe(reason: .caretMoved)
            return .reset(.caretMoved)
        }

        if record.keyCode == Self.backspace {
            if count > 0 { count -= 1; return .retracted }
            // Backspace on an empty buffer deletes something we are not tracking
            // — the space before the word, or the tail of a word we already
            // committed. Reporting `.ignored` was wrong: the chain went on
            // believing those words sit where it left them, and a later
            // replacement would reach across the gap and delete text nobody had
            // looked at.
            return .reset(.caretMoved)
        }

        if Self.boundaryKeyCodes.contains(record.keyCode) {
            let word = currentWord
            wipe(reason: .wordCommitted)
            guard !word.isEmpty else { return .ignored }
            justCommitted = (keys: word, terminator: record.keyCode)
            return .boundary(word: word, terminator: record.keyCode)
        }

        // Function keys, media keys, the Fn row: they produce nothing on screen,
        // but `render` would still ask the layout for a character and could get
        // a control code, which then goes into the replacement as a character
        // that was never there.
        guard record.keyCode < 128, !Self.nonPrintingKeyCodes.contains(record.keyCode) else {
            return .ignored
        }

        // Overflow means something long and word-like is being typed — a token, a
        // hash, a path. Dropping the oldest key would silently corrupt the word,
        // so we let go of the whole thing instead.
        guard count < Self.capacity else {
            // Overflow means something long and word-like is being typed — a
            // token, a hash, a path. Dropping the oldest key would silently
            // corrupt the word, so we let go of the whole thing.
            //
            // And we say so: reporting `.ignored` left the chain believing the
            // previous words were still adjacent to the caret, when in fact an
            // unknown number of characters now sits between them and it.
            wipe(reason: .wordCommitted)
            return .reset(.wordCommitted)
        }

        storage[count] = record
        count += 1
        return .extended
    }

    // MARK: - Clearing

    func wipe(reason: ResetReason) {
        // memset_s, not a plain assignment: the compiler is allowed to elide a
        // store to memory nothing reads again, and this is exactly the store we
        // need it not to elide.
        _ = memset_s(storage.baseAddress, Self.capacity * MemoryLayout<KeyRecord>.stride,
                     0, Self.capacity * MemoryLayout<KeyRecord>.stride)
        count = 0
        // Only a word ending leaves the caret where we think it is; every other
        // reason means it moved, so the committed word stops being reachable.
        if reason != .wordCommitted { justCommitted = nil }
        lastResetReason = reason
    }

    // MARK: - Key classes (positions, identical in every layout)

    private static let backspace: UInt16 = 0x33

    /// Space, tab, return and the keypad enter. Escape too: it ends whatever was
    /// being typed everywhere it means anything.
    static let boundaryKeyCodes: Set<UInt16> = [0x31, 0x30, 0x24, 0x4C, 0x35]

    /// Keys that put nothing on screen: the function row, Help, and the
    /// modifier-like keys that still arrive as key codes.
    static let nonPrintingKeyCodes: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64,   // F1–F8
        0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A,   // F9–F16
        0x40, 0x4F, 0x50, 0x5A,                            // F17–F20
        0x72, 0x3F, 0x39,                                  // Help, Fn, Caps Lock
    ]

    /// Arrows, Home/End, Page Up/Down, forward delete.
    static let caretMovingKeyCodes: Set<UInt16> = [0x7B, 0x7C, 0x7D, 0x7E,
                                                   0x73, 0x77, 0x74, 0x79, 0x75]
}
