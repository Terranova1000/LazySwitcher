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

    var title: String {
        switch self {
        case .doubleShift:   return "Двойное нажатие ⇧ Shift"
        case .doubleOption:  return "Двойное нажатие ⌥ Option"
        case .doubleControl: return "Двойное нажатие ⌃ Control"
        case .doubleCommand: return "Двойное нажатие ⌘ Command"
        case .rightCommand:  return "Правый ⌘ Command"
        case .rightOption:   return "Правый ⌥ Option"
        case .rightControl:  return "Правый ⌃ Control"
        }
    }

    var explanation: String {
        switch self {
        case .doubleShift:
            return "Привычно тем, кто пользовался Caramba. Самый частый повод для жалоб "
                 + "у таких программ — срабатывание при наборе заглавных, поэтому здесь "
                 + "тап засчитывается, только если между нажатием и отпусканием Shift не "
                 + "было ни одной другой клавиши."
        case .doubleOption, .doubleControl, .doubleCommand:
            return "С заглавными не конфликтует вовсе. Может пересекаться с сочетаниями "
                 + "в редакторах кода — если мешает, такое приложение можно выключить "
                 + "во вкладке «Приложения»."
        case .rightCommand, .rightOption, .rightControl:
            return "Одно нажатие вместо двух. Правые модификаторы почти никогда не "
                 + "используются сами по себе, поэтому ложных срабатываний меньше всего. "
                 + "Не подойдёт, если на клавиатуре нет правого модификатора."
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
    var keyCodes: Set<UInt16> {
        switch self {
        case .doubleShift:   return [0x38, 0x3C]
        case .doubleOption:  return [0x3A, 0x3D]
        case .doubleControl: return [0x3B, 0x3E]
        case .doubleCommand: return [0x37, 0x36]
        case .rightCommand:  return [0x36]
        case .rightOption:   return [0x3D]
        case .rightControl:  return [0x3E]
        }
    }

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
    var disqualifyingFlags: [CGEventFlags] {
        [.maskShift, .maskAlternate, .maskControl, .maskCommand].filter { $0 != flag }
    }

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
