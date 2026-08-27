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
        /// Which gesture the user chose.
        var style: HotkeyStyle = .doubleShift
    }

    var config = Config() {
        didSet { if oldValue.style != config.style { reset() } }
    }

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

    /// Abandons the main gesture only.
    ///
    /// Separate from `reset()` because the panic chord is tracked alongside it
    /// and must survive: under a non-Shift style, pressing Shift disqualifies
    /// the main gesture *and* is the first half of the panic chord, so a single
    /// combined reset makes the panic gesture unreachable for every style except
    /// the default.
    private func resetMainGesture() {
        shiftPressedAt = nil
        keyPressedDuringShift = false
        lastTapEndedAt = nil
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
        // The panic chord — both Shifts — is checked FIRST and independently of
        // the chosen style. It has to work when everything else has gone wrong,
        // so it neither moves with the setting nor gets filtered out by it.
        //
        // Order matters here and cost six tests to find. The disqualification
        // below rejects any modifier that is not the one we are watching, and
        // under a non-Shift style that includes Shift itself — so running it
        // first killed the panic chord for every style except the default.
        if Self.isShift(keyCode) {
            if let panic = handlePanicChord(flags: flags, keyCode: keyCode, timestamp: timestamp) {
                return panic
            }
            // Mid-chord: both Shifts are down and we are waiting for a release.
            // Not our main gesture and not something to reset over.
            if bothShiftsSince != nil { return nil }
        }

        // Any modifier that is not ours abandons the gesture in progress — but
        // only the gesture. The panic chord keeps its own state.
        if config.style.disqualifyingFlags.contains(where: { flags.contains($0) }) {
            resetMainGesture()
            return nil
        }

        guard config.style.keyCodes.contains(keyCode) else { return nil }

        let isDown = flags.contains(config.style.flag) && Self.pressed(keyCode, in: flags)

        // A single press of a right-hand modifier: nothing to pair, fire on release.
        if !config.style.requiresDoubleTap {
            if isDown {
                shiftPressedAt = timestamp
                keyPressedDuringShift = false
                return nil
            }
            guard let pressedAt = shiftPressedAt else { return nil }
            shiftPressedAt = nil
            guard !keyPressedDuringShift, timestamp - pressedAt < config.maximumTapDuration else {
                return nil
            }
            return .doubleTapShift
        }

        let isLeft = keyCode == config.style.primaryKeyCode

        if isDown {
            shiftPressedAt = timestamp
            keyPressedDuringShift = false
            return nil
        }

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

    /// Both Shifts held together, then released. Independent of `style` on
    /// purpose — the panic gesture must not move when the main one does.
    private func handlePanicChord(flags: CGEventFlags, keyCode: UInt16,
                                  timestamp: TimeInterval) -> Event? {
        let isLeft = keyCode == Self.leftShiftKeyCode
        let isDown = flags.contains(.maskShift) && Self.pressed(keyCode, in: flags)

        if isDown {
            if isLeft { leftShiftDown = true } else { rightShiftDown = true }
            if leftShiftDown && rightShiftDown {
                if bothShiftsSince == nil { bothShiftsSince = timestamp }
                shiftPressedAt = nil
                keyPressedDuringShift = false
                lastTapEndedAt = nil
            }
            return nil
        }

        if isLeft { leftShiftDown = false } else { rightShiftDown = false }
        guard let since = bothShiftsSince else { panicAlreadyFiredForThisChord = false; return nil }

        bothShiftsSince = nil
        lastTapEndedAt = nil
        shiftPressedAt = nil
        if !panicAlreadyFiredForThisChord, timestamp - since >= config.minimumPanicOverlap {
            panicAlreadyFiredForThisChord = true
            return .panicToggle
        }
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
        let bit = HotkeyStyle.deviceBit(for: keyCode)
        guard bit != 0 else { return false }
        return flags.rawValue & bit != 0
    }
}
