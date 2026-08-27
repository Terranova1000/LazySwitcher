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
        /// Space, tab or return: the word just ended and here it is.
        case boundary(word: [KeyRecord])
        /// Backspace took the last key back off.
        case retracted
        /// Something that invalidates our picture of the text.
        case reset(ResetReason)
        /// Not a key we track at all.
        case ignored
    }

    func append(_ record: KeyRecord, hasCommandControlOrOption: Bool) -> AppendResult {
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
            return .ignored
        }

        if Self.boundaryKeyCodes.contains(record.keyCode) {
            let word = currentWord
            wipe(reason: .wordCommitted)
            return word.isEmpty ? .ignored : .boundary(word: word)
        }

        guard record.keyCode < 128 else { return .ignored }

        // Overflow means something long and word-like is being typed — a token, a
        // hash, a path. Dropping the oldest key would silently corrupt the word,
        // so we let go of the whole thing instead.
        guard count < Self.capacity else {
            wipe(reason: .wordCommitted)
            return .ignored
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
        lastResetReason = reason
    }

    // MARK: - Key classes (positions, identical in every layout)

    private static let backspace: UInt16 = 0x33

    /// Space, tab, return and the keypad enter. Escape too: it ends whatever was
    /// being typed everywhere it means anything.
    static let boundaryKeyCodes: Set<UInt16> = [0x31, 0x30, 0x24, 0x4C, 0x35]

    /// Arrows, Home/End, Page Up/Down, forward delete.
    static let caretMovingKeyCodes: Set<UInt16> = [0x7B, 0x7C, 0x7D, 0x7E,
                                                   0x73, 0x77, 0x74, 0x79, 0x75]
}
