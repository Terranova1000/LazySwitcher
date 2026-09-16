import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Lazy_Switcher

/// One event tap per process, whatever restarts and wake-ups do.
///
/// Reported as "after a while it starts replacing normal Russian words with
/// Latin nonsense, with every letter doubled". The running process had two
/// enabled keyboard taps, both delivering into the same word buffer — measured
/// with `CGGetEventTapList` on the machine it happened on. The second tap came
/// from a restart: the old and the new tap thread shared the fields that held
/// the tap, and one of them lost track of a tap that stayed installed.
///
/// These use real taps, so they need the permission the application has. The
/// test host is the debug build; where it has no access, they skip.
final class TapLifecycleTests: XCTestCase {

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func startedService() throws -> KeyTapService {
        let service = KeyTapService()
        guard service.start() else {
            throw XCTSkip("Тестовому процессу не дали перехват клавиатуры — нужен универсальный доступ")
        }
        addTeardownBlock { service.stop() }
        return service
    }

    func testStartAndStopInstallAndRemoveExactlyOneTap() throws {
        let before = KeyTapService.tapsInstalledByThisProcess()
        let service = try startedService()
        XCTAssertEqual(KeyTapService.tapsInstalledByThisProcess(), before + 1)

        service.stop()
        spin(0.2)
        XCTAssertEqual(KeyTapService.tapsInstalledByThisProcess(), before,
                       "Остановленный сервис оставил перехват в системе")
    }

    /// The reported failure, made deterministic.
    ///
    /// After sleep the heartbeat restarted the tap at the very moment the tap
    /// thread was busy with its own wake-up work. Whichever thread wrote the
    /// shared fields last decided which tap survived. Here the old thread is
    /// held busy on purpose while the restart happens, and released after the
    /// new thread is up — the ordering that used to tear down the new tap and
    /// leave the old one installed with nobody holding it.
    func testRestartWhileTheOldThreadIsBusyLeavesOneLiveTap() throws {
        let before = KeyTapService.tapsInstalledByThisProcess()
        let service = try startedService()

        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        service.performOnTapThread { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "Поток перехвата не взял работу")

        XCTAssertTrue(service.restart())
        release.signal()
        // The old thread finishes, cleans up after itself; the new thread's
        // watchdog makes at least one pass.
        spin(6)

        XCTAssertEqual(KeyTapService.tapsInstalledByThisProcess(), before + 1,
                       "После перезапуска у процесса не один перехват")
        let tick = service.watchdogTick.value
        spin(5.5)
        XCTAssertGreaterThan(service.watchdogTick.value, tick,
                             "Перехват после перезапуска не живёт")
    }

    /// Many restarts, with the wake-up check landing between them.
    func testRepeatedRestartsNeverAccumulateTaps() throws {
        let before = KeyTapService.tapsInstalledByThisProcess()
        let service = try startedService()
        for _ in 0..<20 {
            service.checkAlive()
            XCTAssertTrue(service.restart())
            service.checkAlive()
        }
        spin(0.5)
        XCTAssertEqual(KeyTapService.tapsInstalledByThisProcess(), before + 1)
        // Deliberately no assertion on how long each stop took. Measured apart
        // from the suite, 450 restarts: median 0.13 ms, slowest 4.5 ms, no
        // stop waited out its half second. Inside the full suite one did, once,
        // under load — which says something about the machine at that moment
        // and nothing about correctness: a thread that answers late still
        // removes its own tap, and its events are ignored meanwhile.
    }
}

/// Events from a tap the service no longer stands behind change nothing.
///
/// No permission needed: events are built in memory and handed to the same
/// entry point the tap callback uses, labelled with the thread they came from.
final class StaleTapDeliveryTests: XCTestCase {

    private func keyDown(_ code: Int) -> CGEvent {
        CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
    }

    /// «сообщение» typed on ЙЦУКЕН.
    private let word = [kVK_ANSI_C, kVK_ANSI_J, kVK_ANSI_J, kVK_ANSI_Comma,
                        kVK_ANSI_O, kVK_ANSI_T, kVK_ANSI_Y, kVK_ANSI_B, kVK_ANSI_T]

    func testEventsFromASupersededTapAreNotRecorded() {
        let service = KeyTapService()
        let superseded = KeyTapService.TapThread(serial: 1, service: service)
        let current = KeyTapService.TapThread(serial: 2, service: service)
        service.activeSerial.value = current.serial

        _ = service.handle(type: .keyDown, event: keyDown(kVK_ANSI_A), from: superseded)
        XCTAssertEqual(service.keyDownCount.value, 0)
        XCTAssertEqual(service.staleDeliveries.value, 1)

        _ = service.handle(type: .keyDown, event: keyDown(kVK_ANSI_A), from: current)
        XCTAssertEqual(service.keyDownCount.value, 1)
    }

    /// What the user saw, through the buffer: two taps, the same keystrokes,
    /// and the word still arrives once.
    func testTwoTapsDeliveringTheSameKeysCommitTheWordOnce() {
        let committed = commit(word, deliveredBy: { service in
            let stale = KeyTapService.TapThread(serial: 1, service: service)
            let current = KeyTapService.TapThread(serial: 2, service: service)
            service.activeSerial.value = current.serial
            return [stale, current]
        })
        XCTAssertEqual(committed, word.map { UInt16($0) })
    }

    /// Both deliveries really happen — the check above is what makes the second
    /// one harmless, not some accident of the test.
    func testTheSupersededTapReallyDidDeliverEverything() {
        let service = KeyTapService()
        let stale = KeyTapService.TapThread(serial: 1, service: service)
        let current = KeyTapService.TapThread(serial: 2, service: service)
        service.activeSerial.value = current.serial
        for code in word {
            _ = service.handle(type: .keyDown, event: keyDown(code), from: stale)
            _ = service.handle(type: .keyDown, event: keyDown(code), from: current)
        }
        XCTAssertEqual(service.staleDeliveries.value, UInt64(word.count))
        XCTAssertEqual(service.keyDownCount.value, UInt64(word.count))
    }

    /// And even two taps that both counted — which is what the old design
    /// amounted to — can no longer pour their keys into one word. Each thread
    /// has its own buffer, so the worst two of them can do is say the same
    /// thing twice, and the second one is discarded a layer higher up.
    func testTwoCountingTapsCannotMergeTheirKeysIntoOneWord() {
        let service = KeyTapService()
        let first = KeyTapService.TapThread(serial: 1, service: service)
        let second = KeyTapService.TapThread(serial: 1, service: service)
        service.activeSerial.value = 1

        let done = expectation(description: "два слова")
        done.expectedFulfillmentCount = 2
        var committed: [[UInt16]] = []
        service.onWordCommitted = { word, _ in
            committed.append(word.map(\.keyCode))
            done.fulfill()
        }
        for code in word + [kVK_Space] {
            for owner in [first, second] {
                _ = service.handle(type: .keyDown, event: keyDown(code), from: owner)
            }
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(committed, [word.map { UInt16($0) }, word.map { UInt16($0) }])
    }

    private func commit(_ keys: [Int],
                        deliveredBy makeOwners: (KeyTapService) -> [KeyTapService.TapThread]) -> [UInt16]? {
        let service = KeyTapService()
        let owners = makeOwners(service)
        var committed: [UInt16]?
        let done = expectation(description: "слово закончено")
        service.onWordCommitted = { word, _ in
            committed = word.map(\.keyCode)
            done.fulfill()
        }
        for code in keys + [kVK_Space] {
            for owner in owners {
                _ = service.handle(type: .keyDown, event: keyDown(code), from: owner)
            }
        }
        wait(for: [done], timeout: 2)
        return committed
    }
}

/// When the tap thread gets replaced.
final class TapLivenessTests: XCTestCase {

    func testSilenceIsFirstAskedAboutAndOnlyThenReplaced() {
        var liveness = TapLiveness()
        XCTAssertEqual(liveness.observe(tick: 1, now: 0), .none)
        XCTAssertEqual(liveness.observe(tick: 1, now: 15), .none)
        XCTAssertEqual(liveness.observe(tick: 1, now: 16), .probe)
        XCTAssertEqual(liveness.observe(tick: 1, now: 19), .none, "Спросили — ждём ответа")
        XCTAssertEqual(liveness.observe(tick: 1, now: 21.5), .restart)
    }

    /// The case that caused the restarts: a long stretch without ticks that is
    /// not a dead thread. On the wall clock a quarter of an hour of sleep looks
    /// exactly like this; the thread answers the moment it is asked.
    func testAThreadThatAnswersIsNeverReplaced() {
        var liveness = TapLiveness()
        _ = liveness.observe(tick: 7, now: 0)
        XCTAssertEqual(liveness.observe(tick: 7, now: 900), .probe)
        XCTAssertEqual(liveness.observe(tick: 8, now: 900.02), .none)
        for second in 901...960 {
            XCTAssertEqual(liveness.observe(tick: 8 + UInt64(second / 5), now: TimeInterval(second)), .none)
        }
    }

    func testRestartsAreSpacedApart() {
        var liveness = TapLiveness()
        _ = liveness.observe(tick: 1, now: 0)
        XCTAssertEqual(liveness.observe(tick: 1, now: 16), .probe)
        XCTAssertEqual(liveness.observe(tick: 1, now: 22), .restart)
        // Still silent after the restart.
        XCTAssertEqual(liveness.observe(tick: 1, now: 38), .probe)
        XCTAssertEqual(liveness.observe(tick: 1, now: 44), .none, "С прошлого перезапуска прошло 22 с")
        XCTAssertEqual(liveness.observe(tick: 1, now: 52.5), .restart)
    }
}
