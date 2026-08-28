import CoreGraphics

/// One keystroke as we store it: a position on the keyboard, not a character.
///
/// This is the single most consequential type in the project. Storing the key
/// code rather than the character is what lets us ask "what would this have
/// produced in the other layout" without guessing, and it is why the engine
/// knows nothing about й, q, or any other specific letter. Adding a language
/// later means adding a model, not touching this path.
struct KeyRecord: Equatable {
    let keyCode: UInt16
    /// Only the modifiers that change which character a key produces.
    let shift: Bool
    let option: Bool
    /// Caps Lock at the moment of the keystroke.
    ///
    /// Left out originally, and the consequence was not "capitals look wrong":
    /// the rendered word came out lower-case while the screen showed upper-case,
    /// so the accessibility route selected the right range, compared it with the
    /// wrong string, called it a mismatch — and marked the whole application as
    /// one where accessibility does not work, permanently, for the session.
    let capsLock: Bool
    /// Mach absolute time, for the pause-before-word feature and nothing else.
    let timestamp: UInt64

    init(keyCode: UInt16, shift: Bool = false, option: Bool = false,
         capsLock: Bool = false, timestamp: UInt64 = 0) {
        self.keyCode = keyCode
        self.shift = shift
        self.option = option
        self.capsLock = capsLock
        self.timestamp = timestamp
    }

    init(event: CGEvent, timestamp: UInt64) {
        self.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        self.shift = event.flags.contains(.maskShift)
        self.option = event.flags.contains(.maskAlternate)
        self.capsLock = event.flags.contains(.maskAlphaShift)
        self.timestamp = timestamp
    }
}
