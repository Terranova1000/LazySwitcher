import XCTest
@testable import Lazy_Switcher

/// The guard that decides when we may switch the keyboard layout.
///
/// It is small, it has no UI, and it produced the hardest symptom to diagnose in
/// the project so far: "the layout sometimes stops switching, and after a while
/// it works again". The logic is reproduced here rather than driven through
/// `InputSourceService`, because the real one talks to Text Input Sources — a
/// main-thread-only API that changes the machine's actual keyboard layout, which
/// is not something a test suite should be doing to somebody's computer.
final class LayoutSwitchGuardTests: XCTestCase {

    /// The rule as it now stands: refuse while a change we did not make is still
    /// recent. Compared against **now**, never against the other timestamp.
    private func maySwitch(now: Date, lastOwn: Date, lastManual: Date) -> Bool {
        guard now.timeIntervalSince(lastOwn) > 0.3 else { return false }
        if lastManual > lastOwn, now.timeIntervalSince(lastManual) < 2.0 { return false }
        return true
    }

    /// The defect, written down so it cannot come back.
    ///
    /// The old rule compared the two stored timestamps to each other:
    ///
    ///     lastManual.timeIntervalSince(lastOwn) < 2.0
    ///
    /// Both are fixed values. Once a layout change landed within two seconds of
    /// our own switch, that difference stayed under two seconds forever, and
    /// `lastOwn` could not advance because advancing it required a switch the
    /// guard was refusing. A permanent refusal from a rule meant to last two
    /// seconds.
    func testTheGuardDoesNotLatch() {
        let ourSwitch = Date(timeIntervalSince1970: 1_000_000)
        let somebodyElse = ourSwitch.addingTimeInterval(0.5)   // в пределах двух секунд

        // Прежнее правило: разница между двумя моментами, навсегда 0.5 < 2.0.
        let old = somebodyElse.timeIntervalSince(ourSwitch) < 2.0
        XCTAssertTrue(old, "воспроизводим условие, при котором старое правило залипало")

        // Новое: через пять секунд после чужого переключения мы снова работаем.
        XCTAssertTrue(maySwitch(now: somebodyElse.addingTimeInterval(5),
                                lastOwn: ourSwitch, lastManual: somebodyElse),
                      "Через пять секунд отказ обязан сняться сам")

        // И через минуту, и через час — время идёт, состояние не залипает.
        XCTAssertTrue(maySwitch(now: somebodyElse.addingTimeInterval(3600),
                                lastOwn: ourSwitch, lastManual: somebodyElse))
    }

    /// It still does what it exists for: back off while somebody is undoing us.
    func testItStillBacksOffFromAnActualFight() {
        let ourSwitch = Date(timeIntervalSince1970: 1_000_000)
        let undone = ourSwitch.addingTimeInterval(0.4)
        XCTAssertFalse(maySwitch(now: undone.addingTimeInterval(0.5),
                                 lastOwn: ourSwitch, lastManual: undone),
                       "Пока человек отменяет наше переключение, лезть не надо")
    }

    /// A manual switch that happened *before* ours is not a fight — it is the
    /// ordinary case of switching to English by hand and then mistyping.
    func testAnEarlierManualSwitchDoesNotBlockUs() {
        let manual = Date(timeIntervalSince1970: 1_000_000)
        let ourSwitch = manual.addingTimeInterval(1.0)
        XCTAssertTrue(maySwitch(now: ourSwitch.addingTimeInterval(0.5),
                                lastOwn: ourSwitch, lastManual: manual))
    }

    func testTwoSwitchesInQuickSuccessionAreRefused() {
        let first = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(maySwitch(now: first.addingTimeInterval(0.1),
                                 lastOwn: first, lastManual: .distantPast))
        XCTAssertTrue(maySwitch(now: first.addingTimeInterval(0.4),
                                lastOwn: first, lastManual: .distantPast))
    }

    /// Whatever the state, waiting long enough always restores service. A guard
    /// with no path back to working is the one that produces "it just stopped".
    func testEveryStateRecoversWithTime() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        for ownOffset in [0.0, 0.5, 1.0] {
            for manualOffset in [0.0, 0.3, 0.9, 1.9] {
                let own = base.addingTimeInterval(ownOffset)
                let manual = base.addingTimeInterval(manualOffset)
                XCTAssertTrue(maySwitch(now: base.addingTimeInterval(60),
                                        lastOwn: own, lastManual: manual),
                              "own=\(ownOffset) manual=\(manualOffset): через минуту обязано работать")
            }
        }
    }
}
