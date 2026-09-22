import XCTest
@testable import Lazy_Switcher

/// When it is safe to start rewriting text somebody is typing into.
///
/// A replacement is not one action: it is a lead-in, a backspace every few
/// milliseconds, then the new text. A keystroke landing inside that run is
/// deleted by our own backspaces and one of the characters we meant to delete
/// survives in its place. Measured with the self-test typing at a steady rate,
/// before this rule existed: at 120 ms between keystrokes nothing broke; at 60
/// and 30 ms, half the two-word phrases came back as «rкак ела» or «как lела».
final class TypingRhythmTests: XCTestCase {

    private let burst = 0.048        // a seven-character word, measured

    func testThereIsRoomBeforeTheNextKeystroke() {
        // Typing every 200 ms, quiet for 50: the next key is 150 ms away.
        XCTAssertTrue(TextReplacer.mayStartBurst(quiet: 0.050, rhythm: 0.200, burst: burst))
    }

    func testNoRoomWhenTheNextKeystrokeIsDueInsideTheBurst() {
        // Typing every 60 ms, quiet for 40: the next key is due in 20 ms and
        // the burst takes 48. This is exactly the case that broke words.
        XCTAssertFalse(TextReplacer.mayStartBurst(quiet: 0.040, rhythm: 0.060, burst: burst))
    }

    func testAClearPauseIsEnoughEvenForAFastTypist() {
        // Same fast rhythm, but they have stopped: silent for 90 ms.
        XCTAssertTrue(TextReplacer.mayStartBurst(quiet: 0.090, rhythm: 0.060, burst: burst))
    }

    func testSilenceShorterThanTheBurstIsNeverEnough() {
        XCTAssertFalse(TextReplacer.mayStartBurst(quiet: 0.030, rhythm: 0.400, burst: burst))
    }

    /// The regression that took the undo with it: with nothing typed yet, the
    /// old code answered "infinitely quiet" and `rhythm * 1.5` overflowed, so
    /// no moment was ever safe and every undo was abandoned.
    func testNothingTypedYetIsAlwaysASafeMoment() {
        XCTAssertTrue(TextReplacer.mayStartBurst(quiet: KeyTapService.longSilence,
                                                 rhythm: KeyTapService.slowestAssumedRhythm,
                                                 burst: burst))
        XCTAssertTrue(TextReplacer.mayStartBurst(quiet: .greatestFiniteMagnitude,
                                                 rhythm: .greatestFiniteMagnitude, burst: burst))
        XCTAssertTrue(TextReplacer.mayStartBurst(quiet: .infinity, rhythm: .infinity, burst: burst))
    }

    /// The numbers the tap hands over are always usable in arithmetic.
    func testTheServiceNeverAnswersWithInfinity() {
        let service = KeyTapService()
        XCTAssertTrue(service.secondsSinceLastKeystroke().isFinite)
        XCTAssertTrue(service.recentTypingInterval().isFinite)
        XCTAssertLessThanOrEqual(service.recentTypingInterval(), KeyTapService.slowestAssumedRhythm)
    }
}
