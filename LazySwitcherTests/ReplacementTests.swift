import XCTest
@testable import Lazy_Switcher

final class SyntheticChunkingTests: XCTestCase {

    /// Cutting by UTF-16 units instead of characters can split a surrogate pair
    /// or separate a letter from its combining mark, and what lands in the
    /// document is a replacement glyph. Irrelevant for RU/EN today, and exactly
    /// the sort of thing nobody connects back to this file later.
    func testChunksNeverSplitACharacter() {
        let text = "приветмирвсемдоброгодня"
        let chunks = SyntheticEventSource.chunks(of: text, maxUnits: 8)
        let rebuilt = chunks.flatMap { $0 }
        XCTAssertEqual(String(utf16CodeUnits: rebuilt, count: rebuilt.count), text)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 8) }
    }

    func testEmojiSurvivesChunking() {
        let text = "аб👍вг👨‍👩‍👧де"
        let chunks = SyntheticEventSource.chunks(of: text, maxUnits: 4)
        let rebuilt = chunks.flatMap { $0 }
        XCTAssertEqual(String(utf16CodeUnits: rebuilt, count: rebuilt.count), text)
    }

    func testEmptyTextProducesNoChunks() {
        XCTAssertTrue(SyntheticEventSource.chunks(of: "").isEmpty)
    }

    /// A single character longer than the budget still has to go out whole.
    func testOversizedCharacterIsNotSplit() {
        let chunks = SyntheticEventSource.chunks(of: "👨‍👩‍👧", maxUnits: 2)
        XCTAssertEqual(chunks.count, 1)
    }
}

final class UndoControllerTests: XCTestCase {

    private var undo: UndoController!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        undo = UndoController()
        undo.now = { [unowned self] in clock }
    }

    func testRestoresExactlyWhatWasThere() {
        undo.arm(original: "ghbdtn ", replacement: "привет ", bundleID: "com.apple.Notes")
        let pending = undo.consume()
        XCTAssertEqual(pending?.original, "ghbdtn ",
                       "Откат обязан вернуть байт в байт, иначе доверять нельзя ни туда, ни обратно")
        XCTAssertEqual(pending?.replacement, "привет ")
    }

    func testOnlyOnce() {
        undo.arm(original: "a", replacement: "б", bundleID: "x")
        XCTAssertNotNil(undo.consume())
        XCTAssertNil(undo.consume(), "Второе нажатие не должно откатывать повторно")
    }

    func testExpiresAfterTheWindow() {
        undo.arm(original: "a", replacement: "б", bundleID: "x")
        clock = clock.addingTimeInterval(5.1)
        XCTAssertFalse(undo.isAvailable)
        XCTAssertNil(undo.consume())
    }

    func testStillAvailableJustInsideTheWindow() {
        undo.arm(original: "a", replacement: "б", bundleID: "x")
        clock = clock.addingTimeInterval(4.9)
        XCTAssertTrue(undo.isAvailable)
        XCTAssertNotNil(undo.consume())
    }

    /// Once the caret moves, the characters in front of it are not ours any
    /// more, and undoing would eat someone else's text.
    func testCaretMovementInvalidatesIt() {
        undo.arm(original: "a", replacement: "б", bundleID: "x")
        undo.invalidate()
        XCTAssertFalse(undo.isAvailable)
        XCTAssertNil(undo.consume())
    }
}
