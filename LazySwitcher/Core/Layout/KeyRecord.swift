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
    /// Mach absolute time, for the pause-before-word feature and nothing else.
    let timestamp: UInt64

    init(keyCode: UInt16, shift: Bool = false, option: Bool = false, timestamp: UInt64 = 0) {
        self.keyCode = keyCode
        self.shift = shift
        self.option = option
        self.timestamp = timestamp
    }

    init(event: CGEvent, timestamp: UInt64) {
        self.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        self.shift = event.flags.contains(.maskShift)
        self.option = event.flags.contains(.maskAlternate)
        self.timestamp = timestamp
    }
}
