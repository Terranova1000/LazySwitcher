import CoreGraphics
import Foundation

/// Which gesture triggers a correction.
///
/// The list is the one this class of tool has converged on. Double-tapping a
/// modifier wins because it needs one hand, no reaching and no key that means
/// something else; the disagreement is only about *which* modifier, and that is
/// genuinely personal — a double Shift collides with typing capitals, a double
/// ⌘ collides with nothing but is a longer reach, and people who live in an IDE
/// have their own reasons.
///
/// Punto's own answer, Pause/Break, is not available: Mac keyboards have no such
/// key. That is why every Mac tool in this family ends up on a modifier tap.
enum HotkeyStyle: String, CaseIterable {
    case doubleShift
    case doubleOption
    case doubleControl
    case doubleCommand
    case rightCommand
    case rightOption
    case rightControl

    var title: String { L("hotkey.\(rawValue)") }

    var explanation: String {
        switch self {
        case .doubleShift:
            return L("hotkey.explain.shift")
        case .doubleOption, .doubleControl, .doubleCommand:
            return L("hotkey.explain.otherModifier")
        case .rightCommand, .rightOption, .rightControl:
            return L("hotkey.explain.rightModifier")
        }
    }

    /// True when the gesture is two taps rather than one press.
    var requiresDoubleTap: Bool {
        switch self {
        case .rightCommand, .rightOption, .rightControl: return false
        default: return true
        }
    }

    /// Key codes that count for this gesture.
    ///
    /// Stored, not built on demand. The event-tap callback asks for this on
    /// every modifier press, and returning a fresh `Set` there allocated on the
    /// hot path — which rule 7 forbids outright, and for good reason: the
    /// callback runs synchronously in front of every keystroke on the machine.
    private static let codes: [HotkeyStyle: Set<UInt16>] = [
        .doubleShift:   [0x38, 0x3C],
        .doubleOption:  [0x3A, 0x3D],
        .doubleControl: [0x3B, 0x3E],
        .doubleCommand: [0x37, 0x36],
        .rightCommand:  [0x36],
        .rightOption:   [0x3D],
        .rightControl:  [0x3E],
    ]

    var keyCodes: Set<UInt16> { Self.codes[self] ?? [] }

    /// Lowest key code of the pair, for telling left from right without sorting.
    var primaryKeyCode: UInt16 { Self.primaryCodes[self] ?? 0 }

    private static let primaryCodes: [HotkeyStyle: UInt16] = [
        .doubleShift: 0x38, .doubleOption: 0x3A, .doubleControl: 0x3B,
        .doubleCommand: 0x36, .rightCommand: 0x36, .rightOption: 0x3D,
        .rightControl: 0x3E,
    ]

    /// The flag that is set while this modifier is held.
    var flag: CGEventFlags {
        switch self {
        case .doubleShift:                 return .maskShift
        case .doubleOption, .rightOption:  return .maskAlternate
        case .doubleControl, .rightControl: return .maskControl
        case .doubleCommand, .rightCommand: return .maskCommand
        }
    }

    /// Modifiers that disqualify the gesture — everything except our own.
    /// Stored for the same reason as `keyCodes`: this is read per keystroke.
    var disqualifyingFlags: [CGEventFlags] { Self.disqualifying[self] ?? [] }

    private static let disqualifying: [HotkeyStyle: [CGEventFlags]] = {
        var table: [HotkeyStyle: [CGEventFlags]] = [:]
        for style in HotkeyStyle.allCases {
            table[style] = [.maskShift, .maskAlternate, .maskControl, .maskCommand]
                .filter { $0 != style.flag }
        }
        return table
    }()

    /// Device-specific bit for a given key code, so left and right can be told
    /// apart. `CGEventFlags` only exposes the combined modifier, and the panic
    /// chord needs both halves of Shift distinguished.
    static func deviceBit(for keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 0x38: return 0x00000002      // левый Shift
        case 0x3C: return 0x00000004      // правый Shift
        case 0x3B: return 0x00000001      // левый Control
        case 0x3E: return 0x00002000      // правый Control
        case 0x3A: return 0x00000020      // левый Option
        case 0x3D: return 0x00000040      // правый Option
        case 0x37: return 0x00000008      // левый Command
        case 0x36: return 0x00000010      // правый Command
        default:   return 0
        }
    }
}
