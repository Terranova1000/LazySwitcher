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
        undo.arm(original: "ghbdtn ", replacement: "привет ", bundleID: "com.apple.Notes", generation: 7)
        let pending = undo.consume(currentGeneration: 7)
        XCTAssertEqual(pending?.original, "ghbdtn ",
                       "Откат обязан вернуть байт в байт, иначе доверять нельзя ни туда, ни обратно")
        XCTAssertEqual(pending?.replacement, "привет ")
    }

    func testOnlyOnce() {
        undo.arm(original: "a", replacement: "б", bundleID: "x", generation: 1)
        XCTAssertNotNil(undo.consume(currentGeneration: 1))
        XCTAssertNil(undo.consume(currentGeneration: 1), "Второе нажатие не должно откатывать повторно")
    }

    func testExpiresAfterTheWindow() {
        undo.arm(original: "a", replacement: "б", bundleID: "x", generation: 1)
        clock = clock.addingTimeInterval(5.1)
        XCTAssertFalse(undo.isAvailable)
        XCTAssertNil(undo.consume(currentGeneration: 1))
    }

    func testStillAvailableJustInsideTheWindow() {
        undo.arm(original: "a", replacement: "б", bundleID: "x", generation: 1)
        clock = clock.addingTimeInterval(4.9)
        XCTAssertTrue(undo.isAvailable)
        XCTAssertNotNil(undo.consume(currentGeneration: 1))
    }

    /// Once the caret moves, the characters in front of it are not ours any
    /// more, and undoing would eat someone else's text.
    func testCaretMovementInvalidatesIt() {
        undo.arm(original: "a", replacement: "б", bundleID: "x", generation: 1)
        undo.invalidate()
        XCTAssertFalse(undo.isAvailable)
        XCTAssertNil(undo.consume(currentGeneration: 1))
    }
}


/// The undo must not survive typing.
///
/// Found by reading the code, not by using it, and it is the most dangerous
/// thing the audit turned up. After an automatic replacement the word buffer is
/// empty, so the next letter merely extends it — no reset fires and nothing
/// invalidates anything. The undo stayed armed for its full five seconds while
/// the user carried on writing, and pressing the hotkey then deleted as many
/// characters as the replacement had been, from wherever the caret now was.
final class UndoStalenessTests: XCTestCase {

    private var undo: UndoController!

    override func setUp() {
        super.setUp()
        undo = UndoController()
    }

    func testUndoIsRefusedAfterAnythingIsTyped() {
        undo.arm(original: "ghbdtn ", replacement: "привет ", bundleID: "x", generation: 100)
        // Пользователь напечатал ещё что-то: поколение выросло.
        XCTAssertNil(undo.consume(currentGeneration: 101),
                     "Откат обязан отказаться — иначе он сотрёт только что набранное")
    }

    func testUndoWorksWhenNothingWasTyped() {
        undo.arm(original: "ghbdtn ", replacement: "привет ", bundleID: "x", generation: 100)
        XCTAssertNotNil(undo.consume(currentGeneration: 100))
    }

    /// And a refused undo is forgotten, not left waiting for the generation to
    /// come back around.
    func testARefusedUndoIsDiscarded() {
        undo.arm(original: "a", replacement: "б", bundleID: "x", generation: 5)
        XCTAssertNil(undo.consume(currentGeneration: 6))
        XCTAssertNil(undo.consume(currentGeneration: 5), "Отказавший откат не должен воскресать")
    }
}
