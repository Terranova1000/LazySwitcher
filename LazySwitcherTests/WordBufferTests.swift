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
                                         terminator: KeyRecord(keyCode: VK.space)))
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
            XCTAssertEqual(terminator.keyCode, boundary,
                           "Терминатор нужен, чтобы хоткей знал, что стирать")
        }
    }

    /// Слова нет — завершать нечего. Но и промолчать нельзя: клавиша всё равно
    /// что-то напечатала, и цепочка слов должна об этом узнать (см. разбор
    /// «съеденного переноса строки» ниже).
    func testBoundaryOnAnEmptyBufferIsNotAWord() {
        let result = buffer.append(KeyRecord(keyCode: VK.space), hasCommandControlOrOption: false)
        if case .boundary = result { XCTFail("завершать нечего — слова не было") }
        XCTAssertEqual(result, .reset(.caretMoved))
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

    /// Backspace on an empty buffer is not harmless, and calling it that was a
    /// defect.
    ///
    /// It deletes something we are not tracking — the space before the word, or
    /// the tail of a word already committed. Reporting `.ignored` left the chain
    /// believing those words still sat where it had left them, so a later
    /// replacement could reach across the gap and delete text nobody had looked
    /// at. It is a reset, and everything downstream needs to hear about it.
    func testBackspaceOnEmptyBufferIsAReset() {
        XCTAssertEqual(buffer.append(KeyRecord(keyCode: VK.backspace), hasCommandControlOrOption: false),
                       .reset(.caretMoved))
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
        // A reset, not `.ignored`: the chain has to learn that an unknown number
        // of characters now sits between the previous words and the caret.
        XCTAssertEqual(buffer.append(KeyRecord(keyCode: VK.h), hasCommandControlOrOption: false),
                       .reset(.wordCommitted))
        XCTAssertTrue(buffer.isEmpty, "Обрезать начало значило бы молча испортить слово")
    }
}

/// The bug the user hit in real use: pressing the hotkey ate part of a
/// neighbouring word.
///
/// Cause: the just-finished word stayed reachable for thirty seconds by the
/// clock, and by then the caret had moved. Deleting "that many characters" then
/// removes whatever happens to be in front of the cursor now. The rule is
/// therefore not a time window at all — the word is reachable only while
/// nothing whatsoever has happened since the space.
final class JustCommittedTests: XCTestCase {

    private var buffer: WordBuffer!
    private enum VK {
        static let g: UInt16 = 0x05, h: UInt16 = 0x04, b: UInt16 = 0x0B
        static let space: UInt16 = 0x31, ret: UInt16 = 0x24
        static let leftArrow: UInt16 = 0x7B
    }

    override func setUp() { super.setUp(); buffer = WordBuffer() }

    private func press(_ code: UInt16, chord: Bool = false) {
        _ = buffer.append(KeyRecord(keyCode: code), hasCommandControlOrOption: chord)
    }

    func testWordIsReachableImmediatelyAfterTheSpace() {
        press(VK.g); press(VK.h); press(VK.space)
        XCTAssertEqual(buffer.justCommitted?.keys.map(\.keyCode), [VK.g, VK.h])
        XCTAssertEqual(buffer.justCommitted?.terminator.keyCode, VK.space)
    }

    func testTypingAnythingElseMakesItUnreachable() {
        press(VK.g); press(VK.space)
        press(VK.b)
        XCTAssertNil(buffer.justCommitted,
                     "После нового символа каретка уже не сразу за словом")
    }

    /// Two spaces in a row: the caret has moved one further, so deleting
    /// word+space would take the wrong characters.
    func testASecondSpaceMakesItUnreachable() {
        press(VK.g); press(VK.space)
        press(VK.space)
        XCTAssertNil(buffer.justCommitted)
    }

    func testCaretMovementMakesItUnreachable() {
        press(VK.g); press(VK.space)
        press(VK.leftArrow)
        XCTAssertNil(buffer.justCommitted)
    }

    func testChordMakesItUnreachable() {
        press(VK.g); press(VK.space)
        press(VK.b, chord: true)
        XCTAssertNil(buffer.justCommitted)
    }

    /// A click, a focus change, Secure Input — anything that wipes the buffer
    /// for a reason other than finishing a word.
    func testExternalResetMakesItUnreachable() {
        for reason: WordBuffer.ResetReason in [.mouseClick, .focusChanged, .appChanged,
                                               .secureInput, .idleTimeout] {
            buffer.wipe(reason: .initial)
            press(VK.g); press(VK.space)
            XCTAssertNotNil(buffer.justCommitted)
            buffer.wipe(reason: reason)
            XCTAssertNil(buffer.justCommitted, "Сброс «\(reason)» обязан снимать досягаемость")
        }
    }

    func testFinishingAWordDoesNotClearTheWordItJustFinished() {
        press(VK.g); press(VK.h); press(VK.space)
        XCTAssertNotNil(buffer.justCommitted, "Само завершение слова — единственный случай, когда память остаётся")
    }

    /// Return is recorded, but the caller must not retype it: in most apps it
    /// has already sent the message or submitted the form.
    func testReturnIsRecordedAsTerminatorButIsTheCallersProblem() {
        press(VK.g); press(VK.ret)
        XCTAssertEqual(buffer.justCommitted?.terminator.keyCode, VK.ret)
    }
}


/// Keys that change the screen without our seeing them properly.
final class BufferSynchronisationTests: XCTestCase {

    private enum VK {
        static let g: UInt16 = 0x05, backspace: UInt16 = 0x33
        static let f1: UInt16 = 0x7A, capsLock: UInt16 = 0x39, fn: UInt16 = 0x3F
    }

    /// Function keys put nothing on screen. Letting them into a word meant
    /// `render` asked the layout for a character anyway and could get a control
    /// code — which then went into the replacement as a character that had never
    /// been typed.
    func testNonPrintingKeysStayOutOfTheWord() {
        let buffer = WordBuffer()
        _ = buffer.append(KeyRecord(keyCode: VK.g), hasCommandControlOrOption: false)
        for key in [VK.f1, VK.capsLock, VK.fn] {
            XCTAssertEqual(buffer.append(KeyRecord(keyCode: key), hasCommandControlOrOption: false),
                           .ignored, "Клавиша \(key) ничего не печатает и в слово попадать не должна")
        }
        XCTAssertEqual(buffer.keyCount, 1)
    }

    /// Caps Lock has to travel with the keystroke.
    ///
    /// Without it the rendered word came out lower-case while the screen showed
    /// upper-case. The accessibility route then selected the right range,
    /// compared it against the wrong string, called it a mismatch — and marked
    /// the entire application as one where accessibility does not work, for the
    /// rest of the session.
    func testCapsLockIsRecorded() {
        let plain = KeyRecord(keyCode: VK.g)
        let capsed = KeyRecord(keyCode: VK.g, capsLock: true)
        XCTAssertFalse(plain.capsLock)
        XCTAssertTrue(capsed.capsLock)
        XCTAssertNotEqual(plain, capsed, "Записи должны различаться, иначе состояние теряется")
    }
}

// MARK: - Граница без слова перед ней

/// «Съедает перенос строки»: слово, пробел, Enter, слово на новой строке — и
/// замена дотягивалась назад через перенос, стирала его и поднимала вторую
/// строку к первой.
///
/// Причина была здесь: Enter после пробела завершает пустое слово, и это
/// возвращалось как `.ignored`. Цепочка слов продолжала считать, что её слова
/// лежат вплотную к каретке через обычный пробел, который она умеет
/// перепечатать. На экране между ними был уже перенос.
extension WordBufferTests {

    func testReturnAfterSpaceInvalidatesTheChain() {
        type([VK.g, VK.h, VK.b])
        guard case .boundary = buffer.append(KeyRecord(keyCode: VK.space),
                                             hasCommandControlOrOption: false) else {
            return XCTFail("пробел обязан завершить слово")
        }
        let afterReturn = buffer.append(KeyRecord(keyCode: VK.ret), hasCommandControlOrOption: false)
        XCTAssertEqual(afterReturn, .reset(.caretMoved),
                       "перенос строки обязан обнулить цепочку, иначе замена дотянется через него")
    }

    /// Любая клавиша-граница на пустом буфере что-то печатает и ломает
    /// предположение цепочки о том, что между словами один обычный пробел.
    func testEveryBoundaryKeyOnAnEmptyBufferResets() {
        for boundary in [VK.space, VK.tab, VK.ret] {
            buffer = WordBuffer()
            let result = buffer.append(KeyRecord(keyCode: boundary), hasCommandControlOrOption: false)
            XCTAssertEqual(result, .reset(.caretMoved),
                           "клавиша \(boundary) на пустом буфере обязана обнулить цепочку")
        }
    }

    /// Двойной пробел — тот же случай: разделитель между словами перестал быть
    /// одним пробелом, а перепечатать цепочка умеет только его.
    func testDoubleSpaceResets() {
        type([VK.g, VK.h])
        _ = buffer.append(KeyRecord(keyCode: VK.space), hasCommandControlOrOption: false)
        XCTAssertEqual(buffer.append(KeyRecord(keyCode: VK.space), hasCommandControlOrOption: false),
                       .reset(.caretMoved))
    }

    /// А обычная граница со словом перед ней по-прежнему завершает слово —
    /// правка не должна была ничего сломать в основном пути.
    func testOrdinaryBoundaryStillCommitsTheWord() {
        type([VK.g, VK.h, VK.b])
        guard case .boundary(let word, let terminator) =
                buffer.append(KeyRecord(keyCode: VK.space), hasCommandControlOrOption: false) else {
            return XCTFail("слово перед пробелом обязано завершиться")
        }
        XCTAssertEqual(word.map(\.keyCode), [VK.g, VK.h, VK.b])
        XCTAssertEqual(terminator.keyCode, VK.space)
    }
}

/// Знаки препинания завершают слово так же, как пробел.
///
/// До этого точка, запятая и вопросительный знак становились частью слова, и
/// «ьфкиду?» никогда не превращалось в законченное слово — значит и не
/// исправлялось. Сообщено из настоящей работы, со всеми вариантами сразу.
///
/// Решение о том, что нажатие дало знак препинания, принимает вызывающий: по
/// коду клавиши это неразрешимо, потому что `,` на латинице и **б** на кириллице
/// — одна и та же клавиша.
final class PunctuationBoundaryTests: XCTestCase {

    private var buffer = WordBuffer()

    private func commit(_ terminator: UInt16, endsSentence: Bool,
                        shift: Bool = false) -> KeyRecord? {
        buffer = WordBuffer()
        for code in [UInt16(0x05), UInt16(0x04), UInt16(0x0B)] {
            _ = buffer.append(KeyRecord(keyCode: code), hasCommandControlOrOption: false)
        }
        let end = KeyRecord(keyCode: terminator, shift: shift, option: false,
                            capsLock: false, timestamp: 0)
        guard case .boundary(let word, let recorded) =
                buffer.append(end, hasCommandControlOrOption: false, endsSentence: endsSentence),
              word.count == 3 else { return nil }
        return recorded
    }

    /// Клавиша, давшая знак препинания, завершает слово.
    func testPunctuationEndsAWord() {
        for code in [UInt16(0x2F), UInt16(0x2B), UInt16(0x2C), UInt16(0x12), UInt16(0x29)] {
            XCTAssertNotNil(commit(code, endsSentence: true),
                            "клавиша \(code) со знаком препинания обязана завершать слово")
        }
    }

    /// Та же клавиша, давшая букву, слово не завершает. Это и есть разница
    /// между `.` на латинице и **ю** на кириллице.
    func testTheSameKeyDoesNotEndAWordWhenItTypedALetter() {
        for code in [UInt16(0x2F), UInt16(0x2B), UInt16(0x29)] {
            XCTAssertNil(commit(code, endsSentence: false),
                         "клавиша \(code) на кириллице — буква, слово рвать нельзя")
        }
    }

    func testSpaceStillEndsAWordWithoutBeingCalledPunctuation() {
        XCTAssertNotNil(commit(0x31, endsSentence: false))
    }

    /// Завершитель сохраняется записью целиком, вместе с Shift: иначе «?» и «/»
    /// не различить, а это разные символы.
    func testTerminatorKeepsItsModifiers() {
        let recorded = commit(0x2C, endsSentence: true, shift: true)
        XCTAssertEqual(recorded?.shift, true, "Shift у завершителя обязан сохраниться")
        XCTAssertEqual(recorded?.keyCode, 0x2C)
    }
}
