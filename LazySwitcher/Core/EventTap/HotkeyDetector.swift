import CoreGraphics
import Foundation

/// Recognises a double tap of Shift, and the both-Shifts panic chord.
///
/// This is the single most criticised detail of Caramba, which uses the same
/// gesture: it fires while people type capitals and it collides with IDE
/// shortcuts. The gesture is worth keeping — one hand, no reaching, familiar —
/// but only with a detector strict enough that a capital letter can never be
/// mistaken for it.
///
/// A Shift press counts as a *tap* only when all of these hold:
///   · no key was pressed between Shift going down and coming up
///     (typing "Hello" is Shift↓ H Shift↑ — there is a keyDown in the middle)
///   · it was held for less than 250 ms
///   · no ⌘, ⌃ or ⌥ was down
///   · Secure Input is off
///
/// That last condition is not a nicety. Under Secure Input `keyDown` stops
/// arriving but `flagsChanged` keeps coming, so a detector that watches only
/// modifiers stays fully functional while someone types a password — and would
/// happily fire a text replacement into the password field. Every reaction to
/// `flagsChanged` in this project is gated on Secure Input for that reason.
///
/// Pure state machine: it takes events and timestamps and returns decisions, so
/// it is testable to the millisecond without a keyboard or a GUI.
final class HotkeyDetector {

    enum Event: Equatable {
        case doubleTapShift
        case panicToggle
    }

    struct Config {
        var maximumTapDuration: TimeInterval = 0.250
        var maximumGapBetweenTaps: TimeInterval = 0.300
        /// How long both Shifts must overlap to read as the panic chord.
        var minimumPanicOverlap: TimeInterval = 0.040
    }

    var config = Config()

    // MARK: - State

    private var leftShiftDown = false
    private var rightShiftDown = false
    private var shiftPressedAt: TimeInterval?
    private var keyPressedDuringShift = false
    private var lastTapEndedAt: TimeInterval?
    private var bothShiftsSince: TimeInterval?
    private var panicAlreadyFiredForThisChord = false

    // MARK: - Input

    /// Any non-modifier key. Its only job here is to disqualify the Shift being
    /// held from counting as a tap.
    func noteKeyDown() {
        if shiftPressedAt != nil { keyPressedDuringShift = true }
    }

    /// Everything that invalidates the gesture in progress: Secure Input turning
    /// on, focus moving, the app going away.
    func reset() {
        leftShiftDown = false
        rightShiftDown = false
        shiftPressedAt = nil
        keyPressedDuringShift = false
        lastTapEndedAt = nil
        bothShiftsSince = nil
        panicAlreadyFiredForThisChord = false
    }

    /// - Parameters:
    ///   - flags: modifier state from the event
    ///   - keyCode: the modifier key that changed
    ///   - timestamp: seconds, monotonic
    ///   - secureInputActive: when true nothing fires, full stop
    func handleFlagsChanged(flags: CGEventFlags,
                            keyCode: UInt16,
                            timestamp: TimeInterval,
                            secureInputActive: Bool) -> Event? {
        // Hard stop. Not a filter applied afterwards — nothing below runs.
        guard !secureInputActive else { reset(); return nil }

        // Any other modifier disqualifies the whole gesture.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            reset()
            return nil
        }

        guard Self.isShift(keyCode) else { return nil }

        let isDown = flags.contains(.maskShift) && Self.pressed(keyCode, in: flags)
        let isLeft = keyCode == Self.leftShiftKeyCode

        if isDown {
            if isLeft { leftShiftDown = true } else { rightShiftDown = true }

            if leftShiftDown && rightShiftDown {
                if bothShiftsSince == nil { bothShiftsSince = timestamp }
                // The panic chord is a separate gesture; whatever tap was
                // building is not one.
                shiftPressedAt = nil
                keyPressedDuringShift = false
                lastTapEndedAt = nil
                return nil
            }

            shiftPressedAt = timestamp
            keyPressedDuringShift = false
            return nil
        }

        // Release
        if isLeft { leftShiftDown = false } else { rightShiftDown = false }

        if let since = bothShiftsSince {
            let overlap = timestamp - since
            bothShiftsSince = nil
            lastTapEndedAt = nil
            shiftPressedAt = nil
            if !panicAlreadyFiredForThisChord, overlap >= config.minimumPanicOverlap {
                panicAlreadyFiredForThisChord = true
                return .panicToggle
            }
            return nil
        }
        panicAlreadyFiredForThisChord = false

        guard let pressedAt = shiftPressedAt else { return nil }
        shiftPressedAt = nil

        // Held too long, or used as a real modifier: not a tap.
        guard !keyPressedDuringShift, timestamp - pressedAt < config.maximumTapDuration else {
            lastTapEndedAt = nil
            return nil
        }

        if let previous = lastTapEndedAt, timestamp - previous <= config.maximumGapBetweenTaps {
            lastTapEndedAt = nil
            return .doubleTapShift
        }

        lastTapEndedAt = timestamp
        return nil
    }

    // MARK: - Key codes

    static let leftShiftKeyCode: UInt16 = 0x38
    static let rightShiftKeyCode: UInt16 = 0x3C

    private static func isShift(_ keyCode: UInt16) -> Bool {
        keyCode == leftShiftKeyCode || keyCode == rightShiftKeyCode
    }

    /// `flagsChanged` says which modifiers are now held, not which key moved, so
    /// down-versus-up is read from the device-specific bits.
    private static func pressed(_ keyCode: UInt16, in flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        return keyCode == leftShiftKeyCode ? (raw & UInt64(NX_DEVICELSHIFTKEYMASK)) != 0
                                           : (raw & UInt64(NX_DEVICERSHIFTKEYMASK)) != 0
    }
}

// Device-specific modifier bits, from IOKit's ev_keymap.h. CoreGraphics exposes
// only the combined .maskShift, which cannot tell the two Shift keys apart —
// and telling them apart is exactly what the panic chord needs.
private let NX_DEVICELSHIFTKEYMASK: UInt32 = 0x00000002
private let NX_DEVICERSHIFTKEYMASK: UInt32 = 0x00000004
