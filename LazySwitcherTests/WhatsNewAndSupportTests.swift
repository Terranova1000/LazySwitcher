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

    /// Ищет строку среди всего, что окно реально рисует.
    private func rendersText(_ needle: String, in controller: NSWindowController) -> Bool {
        guard let root = controller.window?.contentView else { return false }
        var stack = [root]
        while let view = stack.popLast() {
            if let field = view as? NSTextField, field.stringValue.contains(needle) {
                // Текст, которому негде поместиться, — это тот же отсутствующий
                // текст. Ровно так и выглядела первая версия этого окна.
                view.layoutSubtreeIfNeeded()
                return field.fittingSize.width > 1 && field.fittingSize.height > 1
            }
            if let text = view as? NSTextView, text.string.contains(needle) {
                return text.fittingSize.height > 1
            }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }

    func testWindowBuilds() {
        let controller = WhatsNewWindowController(notes: "Строка первая\nСтрока вторая")
        XCTAssertNotNil(controller.window)
        XCTAssertFalse(controller.window?.title.isEmpty ?? true)
        controller.close()
    }

    /// Главная проверка этого файла.
    ///
    /// Версия 1.10 вышла с окном, которое открывалось пустым: NSTextView без
    /// заданного размера не показывает ничего. Прежний тест проверял, что окно
    /// существует, — оно существовало. Этот проверяет, что текст видно.
    func testNotesAreActuallyVisible() {
        let controller = WhatsNewWindowController(notes: "Приметная строка для проверки")
        controller.window?.layoutIfNeeded()
        XCTAssertTrue(rendersText("Приметная строка", in: controller),
                      "окно открылось, но текста в нём не видно")
        controller.close()
    }

    /// И то же самое с настоящим текстом из сборки, а не с выдуманным.
    func testBundledNotesAreVisible() throws {
        let notes = try XCTUnwrap(ReleaseNotes.text())
        let firstWords = String(notes.prefix(12))
        let controller = WhatsNewWindowController(notes: notes)
        controller.window?.layoutIfNeeded()
        XCTAssertTrue(rendersText(firstWords, in: controller),
                      "настоящие заметки не отрисовались")
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

/// Истории про лень.
final class StoriesTests: XCTestCase {

    /// Одна и та же сборка обязана показывать одну и ту же историю. Иначе
    /// человек, открывший окно второй раз, увидит другую и решит, что первая
    /// ему померещилась.
    func testSameVersionAlwaysGivesTheSameStory() {
        let a = Stories.forVersion("1.11")
        let b = Stories.forVersion("1.11")
        XCTAssertEqual(a.title, b.title)
    }

    /// Соседние версии не должны попадать на одну историю — иначе смысл
    /// чередования теряется. Первая формула чередовала две штуки из четырёх.
    func testConsecutiveVersionsRotate() {
        let picked = ["1.11", "1.12", "1.13", "1.14"].map {
            Stories.index(for: $0, count: Stories.all.count)
        }
        XCTAssertEqual(Set(picked).count, 4, "четыре версии подряд дали \(picked)")
    }

    /// У истории этой версии есть картинка — специально: релиз, в котором
    /// истории появились, должен показывать их в полном виде.
    func testCurrentVersionHasIllustratedStory() {
        XCTAssertNotNil(Stories.forVersion("1.11").art)
    }

    /// Каждая история обязана иметь переведённые заголовок и текст. Ключ без
    /// перевода отображается как сам ключ, и это видно сразу — но только тому,
    /// кто открыл окно.
    func testEveryStoryIsTranslated() {
        for story in Stories.all {
            XCTAssertNotEqual(L(story.title), story.title, "нет перевода: \(story.title)")
            XCTAssertNotEqual(L(story.body), story.body, "нет перевода: \(story.body)")
            XCTAssertGreaterThan(L(story.body).count, 120, "текст подозрительно короткий")
        }
    }

    /// Картинки, объявленные в историях, должны существовать в сборке.
    func testDeclaredArtExists() {
        for story in Stories.all {
            guard let art = story.art else { continue }
            XCTAssertNotNil(NSImage(named: art), "нет картинки: \(art)")
        }
    }
}
