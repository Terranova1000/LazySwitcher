import XCTest
@testable import Lazy_Switcher

final class WordBufferTests: XCTestCase {

    private var buffer: WordBuffer!
    private enum VK {
        static let g: UInt16 = 0x05, h: UInt16 = 0x04, b: UInt16 = 0x0B
        static let space: UInt16 = 0x31, tab: UInt16 = 0x30, ret: UInt16 = 0x24
        static let backspace: UInt16 = 0x33, leftArrow: UInt16 = 0x7B, home: UInt16 = 0x73
        static let comma: UInt16 = 0x2B, period: UInt16 = 0x2F, semicolon: UInt16 = 0x29
    }

    override func setUp() { super.setUp(); buffer = WordBuffer() }

    @discardableResult
    private func type(_ codes: [UInt16], chord: Bool = false) -> WordBuffer.AppendResult {
        var last: WordBuffer.AppendResult = .ignored
        for code in codes {
            last = buffer.append(KeyRecord(keyCode: code), hasCommandControlOrOption: chord)
        }
        return last
    }

    // MARK: - Growing a word

    func testLettersExtendTheWord() {
        type([VK.g, VK.h, VK.b])
        XCTAssertEqual(buffer.keyCount, 3)
        XCTAssertEqual(buffer.currentWord.map(\.keyCode), [VK.g, VK.h, VK.b])
    }

    func testSpaceCommitsTheWordAndEmptiesTheBuffer() {
        type([VK.g, VK.h])
        let result = buffer.append(KeyRecord(keyCode: VK.space), hasCommandControlOrOption: false)
        XCTAssertEqual(result, .boundary(word: [KeyRecord(keyCode: VK.g), KeyRecord(keyCode: VK.h)],
                                         terminator: VK.space))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testTabAndReturnAlsoCommit() {
        for boundary in [VK.tab, VK.ret] {
            buffer.wipe(reason: .initial)
            type([VK.g])
            guard case .boundary(_, let terminator) = buffer.append(KeyRecord(keyCode: boundary),
                                                                    hasCommandControlOrOption: false) else {
                return XCTFail("Клавиша \(boundary) должна закрывать слово")
            }
            XCTAssertEqual(terminator, boundary, "Терминатор нужен, чтобы хоткей знал, что стирать")
        }
    }

    func testBoundaryOnAnEmptyBufferIsNotAWord() {
        XCTAssertEqual(buffer.append(KeyRecord(keyCode: VK.space), hasCommandControlOrOption: false), .ignored)
    }

    // MARK: - The punctuation that is really letters

    /// On ЙЦУКЕН these keys are ю б ж. Treating them as separators would cut a
    /// third of Russian words in half before anything gets a chance to score them.
    func testPunctuationKeysDoNotEndAWord() {
        for code in [VK.comma, VK.period, VK.semicolon] {
            buffer.wipe(reason: .initial)
            type([VK.g])
            let result = buffer.append(KeyRecord(keyCode: code), hasCommandControlOrOption: false)
            XCTAssertEqual(result, .extended,
                           "Клавиша \(code) на кириллице — буква, а не разделитель")
        }
    }

    // MARK: - Backspace

    func testBackspaceRemovesTheLastKey() {
        type([VK.g, VK.h])
        XCTAssertEqual(buffer.append(KeyRecord(keyCode: VK.backspace), hasCommandControlOrOption: false), .retracted)
        XCTAssertEqual(buffer.currentWord.map(\.keyCode), [VK.g])
    }

    func testBackspaceOnEmptyBufferIsHarmless() {
        XCTAssertEqual(buffer.append(KeyRecord(keyCode: VK.backspace), hasCommandControlOrOption: false), .ignored)
        XCTAssertTrue(buffer.isEmpty)
    }

    // MARK: - Everything that invalidates our picture of the text

    func testChordResetsBuffer() {
        type([VK.g, VK.h])
        XCTAssertEqual(buffer.append(KeyRecord(keyCode: VK.b), hasCommandControlOrOption: true),
                       .reset(.modifierChord))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testCaretMovementResetsBuffer() {
        for code in [VK.leftArrow, VK.home] {
            buffer.wipe(reason: .initial)
            type([VK.g])
            XCTAssertEqual(buffer.append(KeyRecord(keyCode: code), hasCommandControlOrOption: false),
                           .reset(.caretMoved),
                           "После перемещения каретки Backspace сотрёт не то")
            XCTAssertTrue(buffer.isEmpty)
        }
    }

    func testWipeRecordsWhyAndActuallyEmpties() {
        type([VK.g, VK.h, VK.b])
        buffer.wipe(reason: .secureInput)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.keyCount, 0)
        XCTAssertEqual(buffer.currentWord, [])
        XCTAssertEqual(buffer.lastResetReason, .secureInput)
    }

    // MARK: - Capacity

    func testOverflowDropsTheWholeWordRatherThanItsStart() {
        type(Array(repeating: VK.g, count: WordBuffer.capacity))
        XCTAssertEqual(buffer.keyCount, WordBuffer.capacity)
        XCTAssertEqual(buffer.append(KeyRecord(keyCode: VK.h), hasCommandControlOrOption: false), .ignored)
        XCTAssertTrue(buffer.isEmpty, "Обрезать начало значило бы молча испортить слово")
    }
}
