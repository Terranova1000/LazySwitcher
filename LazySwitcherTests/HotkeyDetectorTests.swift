import CoreGraphics
import XCTest
@testable import Lazy_Switcher

final class HotkeyDetectorTests: XCTestCase {

    private var detector: HotkeyDetector!
    private let left = HotkeyDetector.leftShiftKeyCode
    private let right = HotkeyDetector.rightShiftKeyCode
    private let leftBit: UInt64 = 0x00000002
    private let rightBit: UInt64 = 0x00000004

    override func setUp() { super.setUp(); detector = HotkeyDetector() }

    private func down(_ key: UInt16, at t: TimeInterval, secure: Bool = false) -> HotkeyDetector.Event? {
        let bit = key == left ? leftBit : rightBit
        let flags = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | bit)
        return detector.handleFlagsChanged(flags: flags, keyCode: key, timestamp: t, secureInputActive: secure)
    }

    private func up(_ key: UInt16, at t: TimeInterval, secure: Bool = false,
                    otherStillDown: UInt16? = nil) -> HotkeyDetector.Event? {
        var raw: UInt64 = 0
        if let other = otherStillDown {
            raw = CGEventFlags.maskShift.rawValue | (other == left ? leftBit : rightBit)
        }
        return detector.handleFlagsChanged(flags: CGEventFlags(rawValue: raw), keyCode: key,
                                           timestamp: t, secureInputActive: secure)
    }

    // MARK: - The gesture works

    func testTwoQuickTapsFire() {
        XCTAssertNil(down(left, at: 0.00))
        XCTAssertNil(up(left, at: 0.08))
        XCTAssertNil(down(left, at: 0.20))
        XCTAssertEqual(up(left, at: 0.28), .doubleTapShift)
    }

    func testTapsMayMixLeftAndRightShift() {
        XCTAssertNil(down(left, at: 0.00));  XCTAssertNil(up(left, at: 0.06))
        XCTAssertNil(down(right, at: 0.18)); XCTAssertEqual(up(right, at: 0.24), .doubleTapShift)
    }

    // MARK: - Everything that must NOT fire

    /// The complaint that follows this gesture around: it goes off while you
    /// type capitals. "Hello" is Shift↓ H Shift↑, and the keyDown in the middle
    /// is what tells the two apart.
    func testTypingCapitalsNeverFires() {
        XCTAssertNil(down(left, at: 0.00))
        detector.noteKeyDown()                    // "H"
        XCTAssertNil(up(left, at: 0.09))
        XCTAssertNil(down(left, at: 0.20))
        detector.noteKeyDown()                    // "W"
        XCTAssertNil(up(left, at: 0.28), "Набор заглавных не должен считаться двойным тапом")
    }

    func testHoldingShiftTooLongIsNotATap() {
        XCTAssertNil(down(left, at: 0.00))
        XCTAssertNil(up(left, at: 0.40))          // 400 мс — удержание, не тап
        XCTAssertNil(down(left, at: 0.50))
        XCTAssertNil(up(left, at: 0.56))
    }

    func testTapsTooFarApartDoNotPair() {
        XCTAssertNil(down(left, at: 0.00)); XCTAssertNil(up(left, at: 0.05))
        XCTAssertNil(down(left, at: 0.60)); XCTAssertNil(up(left, at: 0.65))
    }

    func testOtherModifiersDisqualify() {
        XCTAssertNil(down(left, at: 0.00)); XCTAssertNil(up(left, at: 0.05))
        _ = detector.handleFlagsChanged(flags: [.maskCommand], keyCode: 0x37,
                                        timestamp: 0.10, secureInputActive: false)
        XCTAssertNil(down(left, at: 0.15))
        XCTAssertNil(up(left, at: 0.20), "После ⌘ гест должен быть сброшен")
    }

    // MARK: - The dangerous one

    /// Under Secure Input keyDown stops arriving but flagsChanged does not, so a
    /// modifier-based hotkey stays live while a password is being typed. This is
    /// the test that says we do not fire there.
    func testNothingFiresUnderSecureInput() {
        XCTAssertNil(down(left, at: 0.00, secure: true))
        XCTAssertNil(up(left, at: 0.05, secure: true))
        XCTAssertNil(down(left, at: 0.15, secure: true))
        XCTAssertNil(up(left, at: 0.20, secure: true), "Двойной Shift не должен сработать в поле пароля")
    }

    func testGestureDoesNotSurviveSecureInputTurningOnMidway() {
        XCTAssertNil(down(left, at: 0.00))
        XCTAssertNil(up(left, at: 0.05))
        XCTAssertNil(down(left, at: 0.15, secure: true))   // сюда пришёл Secure Input
        XCTAssertNil(up(left, at: 0.20), "Половина геста не должна пережить включение Secure Input")
    }

    // MARK: - Panic chord

    /// Fires as soon as the chord starts coming apart — the moment it is
    /// unambiguous — rather than waiting for the second key to come up. Panic is
    /// the gesture people reach for when something is going wrong, and it should
    /// not make them wait.
    func testBothShiftsTogetherFirePanic() {
        XCTAssertNil(down(left, at: 0.00))
        XCTAssertNil(down(right, at: 0.03))
        XCTAssertEqual(up(left, at: 0.15, otherStillDown: right), .panicToggle)
    }

    func testPanicFiresExactlyOncePerChord() {
        XCTAssertNil(down(left, at: 0.00))
        XCTAssertNil(down(right, at: 0.02))
        XCTAssertEqual(up(left, at: 0.10, otherStillDown: right), .panicToggle)
        XCTAssertNil(up(right, at: 0.11), "Второе отпускание не должно сработать повторно")
    }

    func testPanicChordIsNotAlsoReadAsADoubleTap() {
        XCTAssertNil(down(left, at: 0.00))
        XCTAssertNil(down(right, at: 0.02))
        XCTAssertEqual(up(left, at: 0.10, otherStillDown: right), .panicToggle)
        XCTAssertNil(up(right, at: 0.11))
        // Тот же жест не должен догнать нас двойным тапом следом
        XCTAssertNil(down(left, at: 0.20))
        XCTAssertNil(up(left, at: 0.25))
    }

    /// A brush of both Shifts on the way to something else is not the gesture.
    func testTooBriefAnOverlapIsNotPanic() {
        XCTAssertNil(down(left, at: 0.00))
        XCTAssertNil(down(right, at: 0.100))
        XCTAssertNil(up(left, at: 0.110, otherStillDown: right), "10 мс перекрытия — случайность")
    }

    func testPanicDoesNotFireUnderSecureInput() {
        XCTAssertNil(down(left, at: 0.00, secure: true))
        XCTAssertNil(down(right, at: 0.03, secure: true))
        XCTAssertNil(up(left, at: 0.15, secure: true, otherStillDown: right))
        XCTAssertNil(up(right, at: 0.16, secure: true))
    }

    // MARK: - Recovery

    func testDetectorKeepsWorkingAfterAReset() {
        XCTAssertNil(down(left, at: 0.00))
        detector.reset()
        XCTAssertNil(up(left, at: 0.05))
        XCTAssertNil(down(left, at: 1.00)); XCTAssertNil(up(left, at: 1.05))
        XCTAssertNil(down(left, at: 1.15)); XCTAssertEqual(up(left, at: 1.20), .doubleTapShift)
    }
}

/// The other gestures. Each one has to keep the properties that make the
/// default safe — no firing under Secure Input, no firing while a modifier is
/// doing its real job.
final class HotkeyStyleTests: XCTestCase {

    private var detector: HotkeyDetector!

    private func configure(_ style: HotkeyStyle) {
        detector = HotkeyDetector()
        detector.config.style = style
    }

    private func send(_ keyCode: UInt16, down: Bool, at t: TimeInterval,
                      flag: CGEventFlags, secure: Bool = false) -> HotkeyDetector.Event? {
        var raw: UInt64 = 0
        if down { raw = flag.rawValue | HotkeyStyle.deviceBit(for: keyCode) }
        return detector.handleFlagsChanged(flags: CGEventFlags(rawValue: raw), keyCode: keyCode,
                                           timestamp: t, secureInputActive: secure)
    }

    // MARK: - Double taps on other modifiers

    func testDoubleOptionFires() {
        configure(.doubleOption)
        XCTAssertNil(send(0x3A, down: true, at: 0.00, flag: .maskAlternate))
        XCTAssertNil(send(0x3A, down: false, at: 0.06, flag: .maskAlternate))
        XCTAssertNil(send(0x3A, down: true, at: 0.18, flag: .maskAlternate))
        XCTAssertEqual(send(0x3A, down: false, at: 0.24, flag: .maskAlternate), .doubleTapShift)
    }

    func testDoubleCommandFires() {
        configure(.doubleCommand)
        XCTAssertNil(send(0x37, down: true, at: 0.00, flag: .maskCommand))
        XCTAssertNil(send(0x37, down: false, at: 0.05, flag: .maskCommand))
        XCTAssertNil(send(0x37, down: true, at: 0.15, flag: .maskCommand))
        XCTAssertEqual(send(0x37, down: false, at: 0.20, flag: .maskCommand), .doubleTapShift)
    }

    /// ⌘C is Command down, C, Command up. The keyDown in the middle is what
    /// stops a real shortcut from being read as the gesture — the same guard
    /// that protects capitals under the Shift style.
    func testUsingCommandAsAModifierDoesNotFire() {
        configure(.doubleCommand)
        XCTAssertNil(send(0x37, down: true, at: 0.00, flag: .maskCommand))
        detector.noteKeyDown()                       // «C»
        XCTAssertNil(send(0x37, down: false, at: 0.08, flag: .maskCommand))
        XCTAssertNil(send(0x37, down: true, at: 0.18, flag: .maskCommand))
        detector.noteKeyDown()                       // «V»
        XCTAssertNil(send(0x37, down: false, at: 0.24, flag: .maskCommand))
    }

    func testShiftDoesNotFireWhenAnotherStyleIsChosen() {
        configure(.doubleOption)
        XCTAssertNil(send(0x38, down: true, at: 0.00, flag: .maskShift))
        XCTAssertNil(send(0x38, down: false, at: 0.05, flag: .maskShift))
        XCTAssertNil(send(0x38, down: true, at: 0.15, flag: .maskShift))
        XCTAssertNil(send(0x38, down: false, at: 0.20, flag: .maskShift),
                     "Выбран двойной ⌥ — Shift не должен ничего делать")
    }

    // MARK: - Single press of a right-hand modifier

    func testRightCommandFiresOnASinglePress() {
        configure(.rightCommand)
        XCTAssertNil(send(0x36, down: true, at: 0.00, flag: .maskCommand))
        XCTAssertEqual(send(0x36, down: false, at: 0.09, flag: .maskCommand), .doubleTapShift)
    }

    func testLeftCommandDoesNothingWhenRightIsChosen() {
        configure(.rightCommand)
        XCTAssertNil(send(0x37, down: true, at: 0.00, flag: .maskCommand))
        XCTAssertNil(send(0x37, down: false, at: 0.09, flag: .maskCommand))
    }

    func testHoldingTheRightModifierIsNotAPress() {
        configure(.rightOption)
        XCTAssertNil(send(0x3D, down: true, at: 0.00, flag: .maskAlternate))
        XCTAssertNil(send(0x3D, down: false, at: 0.50, flag: .maskAlternate),
                     "Удержание — это работа модификатора, а не жест")
    }

    func testRightModifierUsedInACombinationDoesNotFire() {
        configure(.rightOption)
        XCTAssertNil(send(0x3D, down: true, at: 0.00, flag: .maskAlternate))
        detector.noteKeyDown()
        XCTAssertNil(send(0x3D, down: false, at: 0.10, flag: .maskAlternate))
    }

    // MARK: - Invariants that hold for every style

    func testNoStyleFiresUnderSecureInput() {
        for style in HotkeyStyle.allCases {
            configure(style)
            let key = style.keyCodes.min()!
            _ = send(key, down: true, at: 0.00, flag: style.flag, secure: true)
            _ = send(key, down: false, at: 0.05, flag: style.flag, secure: true)
            _ = send(key, down: true, at: 0.15, flag: style.flag, secure: true)
            XCTAssertNil(send(key, down: false, at: 0.20, flag: style.flag, secure: true),
                         "\(style): не должно срабатывать при Secure Input")
        }
    }

    /// The panic chord stays on both Shifts whatever the main gesture is: it is
    /// what people reach for when something has gone wrong, and a gesture that
    /// moves with a setting is no use then.
    func testPanicChordWorksUnderEveryStyle() {
        for style in HotkeyStyle.allCases {
            configure(style)
            XCTAssertNil(send(0x38, down: true, at: 0.00, flag: .maskShift))
            _ = send(0x3C, down: true, at: 0.03, flag: .maskShift)
            let release = detector.handleFlagsChanged(
                flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue
                                    | HotkeyStyle.deviceBit(for: 0x3C)),
                keyCode: 0x38, timestamp: 0.15, secureInputActive: false)
            XCTAssertEqual(release, .panicToggle, "\(style): паника обязана работать всегда")
        }
    }

    func testEveryStyleHasKeyCodesAndATitle() {
        for style in HotkeyStyle.allCases {
            XCTAssertFalse(style.keyCodes.isEmpty, "\(style)")
            XCTAssertFalse(style.title.isEmpty, "\(style)")
            XCTAssertFalse(style.disqualifyingFlags.contains(style.flag),
                           "\(style): собственный модификатор не может сам себя дисквалифицировать")
        }
    }
}
