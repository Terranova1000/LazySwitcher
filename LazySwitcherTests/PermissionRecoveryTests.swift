import XCTest
@testable import Lazy_Switcher

/// The rule that decides whether this program may restart itself.
///
/// Worth testing on its own because the failure mode is not a wrong answer on
/// screen — it is a machine launching copies of an application once a second
/// until someone notices.
final class PermissionRecoveryTests: XCTestCase {

    private func decide(trusted: Bool = true,
                        trustedAtStart: Bool = false,
                        tapStarted: Bool = false,
                        alreadyRelaunched: Bool = false,
                        secondsSinceLastRelaunch: Double = .greatestFiniteMagnitude,
                        elapsed: Double = 1) -> PermissionRecovery.Action {
        PermissionRecovery.decide(trusted: trusted,
                                  trustedAtStart: trustedAtStart,
                                  tapStarted: tapStarted,
                                  alreadyRelaunched: alreadyRelaunched,
                                  secondsSinceLastRelaunch: secondsSinceLastRelaunch,
                                  elapsed: elapsed)
    }

    // MARK: - Отказ от перезапуска

    /// Главная проверка этого файла: состояние «галочка зелёная, всё мертво»
    /// перезапуском не лечится, и пытаться нельзя — это и есть цикл.
    func testAlreadyTrustedAtStartNeverRelaunches() {
        XCTAssertEqual(decide(trustedAtStart: true, tapStarted: false), .stuck)
    }

    /// Даже если предыдущий запуск был давно и флаг в этом процессе чист.
    func testAlreadyTrustedAtStartNeverRelaunchesEvenWithCleanHistory() {
        XCTAssertEqual(decide(trustedAtStart: true,
                              alreadyRelaunched: false,
                              secondsSinceLastRelaunch: .greatestFiniteMagnitude),
                       .stuck)
    }

    /// Второй перезапуск в одном процессе запрещён при любых обстоятельствах.
    func testNeverRelaunchesTwiceInOneProcess() {
        XCTAssertEqual(decide(alreadyRelaunched: true), .stuck)
    }

    /// И сразу после перезапуска — тоже, даже в новом процессе, где флаг чист.
    /// Это то, что разрывает цикл между процессами, а не внутри одного.
    func testRefusesRelaunchSoonAfterPreviousOne() {
        XCTAssertEqual(decide(secondsSinceLastRelaunch: 3), .stuck)
        XCTAssertEqual(decide(secondsSinceLastRelaunch: 60), .stuck)
    }

    // MARK: - Разрешение перезапуска

    /// Ради этого случая механизм и существует: доступ выдали при работающем
    /// приложении, наш кеш CGPreflight устарел, свежий процесс увидит грант.
    func testRelaunchesWhenAccessArrivedAfterLaunch() {
        XCTAssertEqual(decide(trustedAtStart: false, tapStarted: false), .relaunch)
    }

    func testRelaunchesAgainLongAfterAPreviousRelaunch() {
        XCTAssertEqual(decide(secondsSinceLastRelaunch: 3600), .relaunch)
    }

    // MARK: - Обычные исходы

    func testGrantedWhenTapOpens() {
        XCTAssertEqual(decide(tapStarted: true), .granted)
        // Даже если раньше перезапускались — успех есть успех.
        XCTAssertEqual(decide(tapStarted: true, alreadyRelaunched: true), .granted)
    }

    /// Успех важнее «залипания»: если tap поднялся, состояние не залипшее.
    func testTapSuccessBeatsStuckDiagnosis() {
        XCTAssertEqual(decide(trustedAtStart: true, tapStarted: true), .granted)
    }

    func testWaitsWhileNobodyHasGrantedAnything() {
        XCTAssertEqual(decide(trusted: false, elapsed: 5), .keepWaiting)
        XCTAssertEqual(decide(trusted: false, elapsed: 300), .keepWaiting)
    }

    func testStopsPollingAfterFiveMinutes() {
        XCTAssertEqual(decide(trusted: false, elapsed: 301), .giveUp)
    }

    /// Ожидание не зависит от истории перезапусков — только от доверия.
    func testUntrustedIgnoresRelaunchHistory() {
        XCTAssertEqual(decide(trusted: false, alreadyRelaunched: true, elapsed: 5), .keepWaiting)
    }
}
