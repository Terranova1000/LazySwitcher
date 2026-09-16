import Carbon.HIToolbox
import XCTest
@testable import Lazy_Switcher

/// Punctuation at the end of a word, and punctuation that only looks like it.
///
/// 1.13 made a full stop or a comma end the word, so that `ьфкиду.` could be
/// fixed without waiting for a space. On the Latin layout it also cut Russian
/// words typed there by mistake at every б, ю and ж: `cjj,otybt` («сообщение»)
/// came out as «cjj,щение». Nothing tested a word with those letters inside.
final class WordEndingTests: XCTestCase {

    private var mapper: KeyMapper!
    private var latin: KeyMapper.Table!
    private var cyrillic: KeyMapper.Table!
    private var latinToCyrillic: Scorer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundle = Bundle(for: AppDelegate.self)
        func model(_ name: String) throws -> LanguageModel {
            guard let url = bundle.url(forResource: name, withExtension: "lsmodel") else {
                throw XCTSkip("Нет модели \(name).lsmodel")
            }
            return try LanguageModel(contentsOf: url)
        }
        mapper = KeyMapper()
        latin = try table("en")
        cyrillic = try table("ru")
        latinToCyrillic = Scorer(models: .init(source: try model("en"), target: try model("ru")))
    }

    private func table(_ code: String) throws -> KeyMapper.Table {
        for source in InputSourceService.enabledKeyboardLayouts()
        where InputSourceService.primaryLanguage(of: source) == code {
            if let table = mapper.table(for: source) { return table }
        }
        throw XCTSkip("Раскладка «\(code)» не установлена")
    }

    // MARK: - Which keys end a word at once

    private func marks(_ keys: Set<UInt32>, in table: KeyMapper.Table) -> Set<String> {
        Set(keys.compactMap { table.character(keyCode: UInt16($0 / 2), shift: $0 % 2 == 1) })
    }

    private func slot(_ keyCode: Int, shift: Bool = false) -> UInt32 {
        UInt32(keyCode) * 2 + (shift ? 1 : 0)
    }

    /// Checked by key, not by character: the keypad also types a full stop,
    /// and that one is no letter anywhere, so it rightly ends a word.
    func testOnTheLatinLayoutOnlyMarksThatAreNotCyrillicLettersEndAWord() {
        let found = mapper.sentencePunctuation(in: latin, other: cyrillic)
        XCTAssertTrue(found.contains(slot(kVK_ANSI_Slash, shift: true)), "?")
        XCTAssertTrue(found.contains(slot(kVK_ANSI_1, shift: true)), "!")
        for (key, shift, name) in [(kVK_ANSI_Comma, false, "б"), (kVK_ANSI_Period, false, "ю"),
                                   (kVK_ANSI_Semicolon, false, "ж"), (kVK_ANSI_Semicolon, true, "Ж")] {
            XCTAssertFalse(found.contains(slot(key, shift: shift)),
                           "Клавиша «\(name)» на латинице — буква кириллицы, слово на ней не кончается")
        }
    }

    func testOnTheCyrillicLayoutEveryMarkEndsAWord() {
        let found = marks(mapper.sentencePunctuation(in: cyrillic, other: latin), in: cyrillic)
        for mark in [".", ",", "!", "?", ";", ":"] {
            XCTAssertTrue(found.contains(mark), "«\(mark)» на кириллице должен заканчивать слово")
        }
    }

    // MARK: - Settling the ending once the word is over

    private func settle(_ latinText: String) throws -> WordEnding.Reading {
        let keys = try XCTUnwrap(mapper.keystrokes(of: latinText, in: latin), latinText)
        return try XCTUnwrap(WordEnding.resolve(keys, mapper: mapper, source: latin,
                                                target: cyrillic, scorer: latinToCyrillic))
    }

    func testTheReportedWordKeepsItsLetterB() throws {
        let reading = try settle("cjj,otybt")
        XCTAssertEqual(reading.alternative, "сообщение")
        XCTAssertEqual(reading.marks, "")
    }

    func testAFullStopOrCommaAfterAMistypedWordStaysPunctuation() throws {
        for (typed, word, mark) in [("ghbdtn.", "привет", "."), ("ghbdtn,", "привет", ","),
                                    ("rfr,", "как", ","), ("ult.", "где", "."),
                                    ("cjj,otybt.", "сообщение", ".")] {
            let reading = try settle(typed)
            XCTAssertEqual(reading.alternative, word, typed)
            XCTAssertEqual(reading.marks, mark, typed)
        }
    }

    func testAWordThatEndsInTheLetterKeepsIt() throws {
        for (typed, word) in [("cdj.", "свою"), ("k.,k.", "люблю"), ("e;", "уж"),
                              ("[kt,", "хлеб"), ("vj;tn", "может")] {
            let reading = try settle(typed)
            XCTAssertEqual(reading.alternative, word, typed)
            XCTAssertEqual(reading.marks, "", typed)
        }
    }

    /// English typed on the English layout is left as it is — and the comma
    /// is still a comma, so the word itself is what gets judged.
    func testAnEnglishWordWithACommaIsJudgedWithoutIt() throws {
        let reading = try settle("hello,")
        XCTAssertEqual(reading.typed, "hello")
        XCTAssertEqual(reading.marks, ",")
        XCTAssertNotEqual(latinToCyrillic.decide(typed: reading.typed, converted: reading.alternative).0,
                          .convert)
    }
}
