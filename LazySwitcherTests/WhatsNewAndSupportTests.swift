import AppKit
import XCTest
@testable import Lazy_Switcher

/// Когда показывать «что нового».
final class ReleaseNotesTests: XCTestCase {

    /// Человек, увидевший приложение впервые, не должен встречать список
    /// изменений версии, которой он никогда не пользовался. Ему показывают
    /// приветствие, а это — другое.
    func testFirstRunShowsNothing() {
        XCTAssertFalse(ReleaseNotes.shouldPresent(seenVersion: nil, current: "1.10", hasNotes: true))
    }

    func testShowsWhenVersionChanged() {
        XCTAssertTrue(ReleaseNotes.shouldPresent(seenVersion: "1.9.4", current: "1.10", hasNotes: true))
    }

    func testStaysQuietOnTheSameVersion() {
        XCTAssertFalse(ReleaseNotes.shouldPresent(seenVersion: "1.10", current: "1.10", hasNotes: true))
    }

    /// Даже откат назад — это смена версии, и показать изменения уместно:
    /// человек видит, чего в этой сборке нет.
    func testDowngradeCounts() {
        XCTAssertTrue(ReleaseNotes.shouldPresent(seenVersion: "1.10", current: "1.9.4", hasNotes: true))
    }

    func testNothingToShowMeansNoWindow() {
        XCTAssertFalse(ReleaseNotes.shouldPresent(seenVersion: "1.9.4", current: "1.10", hasNotes: false))
    }

    /// Текст обязан лежать в сборке: окно читает его из бандла, а не из сети.
    func testNotesAreBundled() {
        XCTAssertNotNil(ReleaseNotes.text(), "WhatsNew.txt не попал в бандл")
    }
}

/// Когда просить о поддержке.
///
/// Правила проверяются, хотя показ выключен: включаться он будет одной строкой,
/// и в этот момент важно, чтобы поведение уже было проверено, а не сочинялось
/// заново.
final class SupportPromptTests: XCTestCase {

    private let week = SupportPrompt.quietPeriodBeforeFirstAsk
    private let quarter = SupportPrompt.quietPeriodBetweenAsks
    private let now = Date()

    private func ask(enabled: Bool = true, silenced: Bool = false,
                     firstRun: Date?, lastAsked: Date? = nil) -> Bool {
        SupportPrompt.shouldAsk(enabled: enabled, silenced: silenced,
                                firstRun: firstRun, lastAsked: lastAsked, now: now)
    }

    /// Пока адреса нет, не показывается ничего и ни при каких условиях.
    func testDisabledUntilThereIsSomewhereToSendPeople() {
        XCTAssertNil(SupportPrompt.destination, "адрес не задан — показ обязан быть выключен")
        XCTAssertFalse(SupportPrompt.isEnabled)
        XCTAssertFalse(ask(enabled: SupportPrompt.isEnabled,
                           firstRun: now.addingTimeInterval(-10 * week)))
    }

    func testNotInTheFirstWeek() {
        XCTAssertFalse(ask(firstRun: now.addingTimeInterval(-week + 3600)))
    }

    func testAsksAfterAWeek() {
        XCTAssertTrue(ask(firstRun: now.addingTimeInterval(-week - 60)))
    }

    func testNeverAgainMeansNeverAgain() {
        XCTAssertFalse(ask(silenced: true, firstRun: now.addingTimeInterval(-10 * week)))
    }

    func testDoesNotAskTwiceInAQuarter() {
        XCTAssertFalse(ask(firstRun: now.addingTimeInterval(-10 * week),
                           lastAsked: now.addingTimeInterval(-quarter + 3600)))
    }

    func testAsksAgainAfterAQuarter() {
        XCTAssertTrue(ask(firstRun: now.addingTimeInterval(-10 * week),
                          lastAsked: now.addingTimeInterval(-quarter - 3600)))
    }

    /// Установка, поставленная до появления этой функции, даты первого запуска
    /// не имеет. Спрашивать её сразу нельзя — отсчёт начинается с этого запуска.
    func testNoFirstRunDateMeansNoAsk() {
        XCTAssertFalse(ask(firstRun: nil))
    }
}

/// Окно «что нового» — проверка, что оно вообще строится.
///
/// Интерфейс собирается кодом, и половина способов его сломать — это
/// ограничения, которые не сходятся, или отсутствующий ресурс. И то и другое
/// проявляется только при построении окна, а не при компиляции.
final class WhatsNewWindowTests: XCTestCase {

    func testWindowBuilds() {
        let controller = WhatsNewWindowController(notes: "Строка первая\nСтрока вторая")
        XCTAssertNotNil(controller.window)
        XCTAssertFalse(controller.window?.title.isEmpty ?? true)
        controller.close()
    }

    /// Пустых заметок быть не должно, но окно на них падать тоже не должно.
    func testWindowSurvivesEmptyNotes() {
        let controller = WhatsNewWindowController(notes: "")
        XCTAssertNotNil(controller.window)
        controller.close()
    }

    /// Баннер обязан быть в сборке: без него окно выглядит сломанным.
    func testBannerIsBundled() {
        XCTAssertNotNil(NSImage(named: "Banner"))
    }
}
