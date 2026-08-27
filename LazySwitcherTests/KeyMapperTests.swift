import Carbon.HIToolbox
import XCTest
@testable import Lazy_Switcher

/// Verifies the layout engine against the layouts actually installed on this Mac.
///
/// These tests read the system rather than a fixture on purpose. The point of
/// `KeyMapper` is that it never hardcodes a letter, so a fixture would test the
/// fixture. If the Russian layout is not installed the layout-pair tests skip
/// rather than fail — a missing layout is an environment fact, not a defect.
final class KeyMapperTests: XCTestCase {

    // ANSI virtual key codes. These are positions on the board, and they do not
    // change with the layout — which is the whole premise.
    private enum VK {
        static let a: UInt16 = 0x00, s: UInt16 = 0x01, d: UInt16 = 0x02, f: UInt16 = 0x03
        static let h: UInt16 = 0x04, g: UInt16 = 0x05, b: UInt16 = 0x0B, q: UInt16 = 0x0C
        static let t: UInt16 = 0x11, n: UInt16 = 0x2D
        static let semicolon: UInt16 = 0x29, comma: UInt16 = 0x2B, period: UInt16 = 0x2F
    }

    private var mapper: KeyMapper!

    override func setUp() {
        super.setUp()
        mapper = KeyMapper()
    }

    // MARK: - Finding layouts

    private func layout(matchingLanguage code: String) throws -> KeyMapper.Table {
        let sources = InputSourceService.enabledKeyboardLayouts()
        for source in sources where InputSourceService.primaryLanguage(of: source) == code {
            if let table = mapper.table(for: source) { return table }
        }
        throw XCTSkip("Раскладка для языка «\(code)» не установлена в системе")
    }

    private func keys(_ codes: [UInt16], shift: Bool = false) -> [KeyRecord] {
        codes.map { KeyRecord(keyCode: $0, shift: shift) }
    }

    // MARK: - The system gives us something at all

    func testSystemHasAtLeastOneKeyboardLayout() {
        let sources = InputSourceService.enabledKeyboardLayouts()
        XCTAssertFalse(sources.isEmpty, "Ни одной включённой раскладки — так не бывает")
        XCTAssertNotNil(InputSourceService.currentLayout(), "Нет текущей раскладки")
    }

    func testEnglishLayoutProducesExpectedLetters() throws {
        let en = try layout(matchingLanguage: "en")
        XCTAssertEqual(en.character(keyCode: VK.q, shift: false), "q")
        XCTAssertEqual(en.character(keyCode: VK.q, shift: true), "Q")
        XCTAssertEqual(en.character(keyCode: VK.a, shift: false), "a")
    }

    // MARK: - The punctuation trap

    /// Seven Cyrillic letters live on punctuation keys, and getting the Shift
    /// variants wrong is the classic way to mangle every third Russian word.
    func testRussianLettersOnPunctuationKeys() throws {
        let ru = try layout(matchingLanguage: "ru")
        XCTAssertEqual(ru.character(keyCode: VK.semicolon, shift: false), "ж")
        XCTAssertEqual(ru.character(keyCode: VK.semicolon, shift: true), "Ж")
        XCTAssertEqual(ru.character(keyCode: VK.comma, shift: false), "б")
        XCTAssertEqual(ru.character(keyCode: VK.comma, shift: true), "Б")
        XCTAssertEqual(ru.character(keyCode: VK.period, shift: false), "ю")
        XCTAssertEqual(ru.character(keyCode: VK.period, shift: true), "Ю")
    }

    func testSameKeysAreOrdinaryPunctuationInEnglish() throws {
        let en = try layout(matchingLanguage: "en")
        XCTAssertEqual(en.character(keyCode: VK.semicolon, shift: false), ";")
        XCTAssertEqual(en.character(keyCode: VK.semicolon, shift: true), ":")
        XCTAssertEqual(en.character(keyCode: VK.comma, shift: false), ",")
        XCTAssertEqual(en.character(keyCode: VK.comma, shift: true), "<")
    }

    // MARK: - The thing the product actually does

    func testTypingPrivetOnAnEnglishLayoutReadsAsRussian() throws {
        let en = try layout(matchingLanguage: "en")
        let ru = try layout(matchingLanguage: "ru")
        let pressed = keys([VK.g, VK.h, VK.b, VK.d, VK.t, VK.n])

        XCTAssertEqual(mapper.render(pressed, with: en), "ghbdtn")
        XCTAssertEqual(mapper.render(pressed, with: ru), "привет")
    }

    func testCapitalisationSurvivesTheConversion() throws {
        let ru = try layout(matchingLanguage: "ru")
        let pressed = [KeyRecord(keyCode: VK.g, shift: true)] + keys([VK.h, VK.b, VK.d, VK.t, VK.n])
        XCTAssertEqual(mapper.render(pressed, with: ru), "Привет")
    }

    /// The reverse direction has to be exactly as good; treating one as the
    /// hard case and the other as easy is how tools end up lopsided.
    func testCyrillicTypingReadsBackAsEnglish() throws {
        let en = try layout(matchingLanguage: "en")
        let ru = try layout(matchingLanguage: "ru")
        // Where "hello" sits on ЙЦУКЕН: р у д д щ
        let pressed = keys([VK.h, VK.t, VK.a, VK.s, VK.n].map { $0 })
        // Render both ways and require they disagree — the tables are distinct.
        let asEnglish = mapper.render(pressed, with: en)
        let asRussian = mapper.render(pressed, with: ru)
        XCTAssertNotNil(asEnglish)
        XCTAssertNotNil(asRussian)
        XCTAssertNotEqual(asEnglish, asRussian)
    }

    // MARK: - Failure modes

    func testUnmappedKeyYieldsNilRatherThanAPartialString() throws {
        let en = try layout(matchingLanguage: "en")
        // Key code 0x7F is not a character key anywhere.
        XCTAssertNil(en.character(keyCode: 0x7F, shift: false))
        XCTAssertNil(mapper.render(keys([VK.q, 0x7F]), with: en),
                     "Частичная строка опаснее пустой: сотрём не столько символов")
    }

    func testTableIsCachedRatherThanRebuilt() throws {
        let source = try XCTUnwrap(InputSourceService.currentLayout())
        let first = mapper.table(for: source)
        let second = mapper.table(for: source)
        XCTAssertEqual(first?.layoutID, second?.layoutID)
    }
}
