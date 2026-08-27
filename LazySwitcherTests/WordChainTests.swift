import XCTest
@testable import Lazy_Switcher

/// The chain converts words that on their own must never be converted, so its
/// boundaries matter more than its reach.
///
/// A three-character word carries a 2.78% false-positive rate alone
/// (03-ALGORITHM.md §14) — unusable. Riding on a confident neighbour makes it
/// safe, but only while every one of these conditions holds.
final class WordChainTests: XCTestCase {

    private func evidence(typedIsWord: Bool, convertedIsWord: Bool,
                          perCharacter: Double = 0, length: Int = 3) -> Scorer.Evidence {
        var e = Scorer.Evidence()
        e.typedIsKnownWord = typedIsWord
        e.convertedIsKnownWord = convertedIsWord
        e.perCharacter = perCharacter
        e.length = length
        return e
    }

    private func entry(typed: String = "xnj", alternative: String = "что",
                       separator: String = " ", converted: Bool = false,
                       evidence e: Scorer.Evidence? = nil) -> WordChain.Entry {
        .init(typed: typed, alternative: alternative, separator: separator,
              evidence: e ?? evidence(typedIsWord: false, convertedIsWord: true),
              converted: converted)
    }

    // MARK: - The case the user reported

    func testShortWordIsRescuedByTheNextOne() {
        var chain = WordChain()
        chain.append(entry())                       // «xnj» — само по себе слишком короткое
        let rescued = chain.retroactiveCandidates()
        XCTAssertEqual(rescued.count, 1)
        XCTAssertEqual(rescued.first?.alternative, "что")
    }

    func testARunOfShortWordsIsRescuedInReadingOrder() {
        var chain = WordChain()
        chain.append(entry(typed: "d", alternative: "в"))
        chain.append(entry(typed: "'njn", alternative: "этот"))
        let rescued = chain.retroactiveCandidates()
        XCTAssertEqual(rescued.map(\.typed), ["d", "'njn"],
                       "Порядок должен быть как в тексте, иначе строка соберётся задом наперёд")
    }

    // MARK: - Where the chain must stop

    /// The protection that keeps "a", "и", "no", "он" out of a neighbour's run:
    /// a real word of the language being typed is never swept along.
    func testARealWordIsNeverSweptAlong() {
        var chain = WordChain()
        chain.append(entry(typed: "a", alternative: "ф",
                           evidence: evidence(typedIsWord: true, convertedIsWord: false, length: 1)))
        XCTAssertTrue(chain.retroactiveCandidates().isEmpty)
    }

    /// Neither reading is a word: a name, an abbreviation, a typo. Leave it.
    func testGibberishIsNotSweptAlong() {
        var chain = WordChain()
        chain.append(entry(typed: "qwrt", alternative: "йцке",
                           evidence: evidence(typedIsWord: false, convertedIsWord: false,
                                              perCharacter: -0.4)))
        XCTAssertTrue(chain.retroactiveCandidates().isEmpty)
    }

    func testAlreadyConvertedWordsAreNotTouchedAgain() {
        var chain = WordChain()
        chain.append(entry(converted: true))
        XCTAssertTrue(chain.retroactiveCandidates().isEmpty)
    }

    /// Only a plain space can be put back. A Tab moved focus; a Return has
    /// usually sent the message already.
    func testChainStopsAtAnythingButASpace() {
        for separator in ["", "\n", "\t"] {
            var chain = WordChain()
            chain.append(entry(separator: separator))
            XCTAssertTrue(chain.retroactiveCandidates().isEmpty,
                          "Разделитель «\(separator.debugDescription)» обязан обрывать цепочку")
        }
    }

    func testChainStopsAtTheFirstUnsuitableWord() {
        var chain = WordChain()
        chain.append(entry(typed: "xnj", alternative: "что"))          // годится
        chain.append(entry(typed: "a", alternative: "ф",
                           evidence: evidence(typedIsWord: true, convertedIsWord: false)))  // нет
        chain.append(entry(typed: "yt", alternative: "не"))            // годится
        // Считаем справа налево и упираемся в «a» — дальше не идём, хотя там есть годное.
        XCTAssertEqual(chain.retroactiveCandidates().map(\.typed), ["yt"])
    }

    func testLookbackIsBounded() {
        var chain = WordChain()
        for _ in 0..<8 { chain.append(entry()) }
        XCTAssertEqual(chain.retroactiveCandidates().count, WordChain.maximumLookback,
                       "Переписывать полстроки задним числом страшнее, чем полезнее")
    }

    func testClearingLosesEverything() {
        var chain = WordChain()
        chain.append(entry())
        chain.clear()
        XCTAssertTrue(chain.retroactiveCandidates().isEmpty)
        XCTAssertFalse(chain.previousWasConverted)
    }

    // MARK: - Forward inheritance

    func testShortWordMayFollowAConvertedNeighbour() {
        var chain = WordChain()
        chain.append(entry(converted: true))
        XCTAssertTrue(chain.previousWasConverted)
        XCTAssertTrue(WordChain.mayInherit(evidence(typedIsWord: false, convertedIsWord: true)))
    }

    func testARealWordDoesNotInherit() {
        XCTAssertFalse(WordChain.mayInherit(evidence(typedIsWord: true, convertedIsWord: false)),
                       "Настоящее слово не должно менять себя за компанию с соседом")
    }

    func testGibberishDoesNotInherit() {
        XCTAssertFalse(WordChain.mayInherit(
            evidence(typedIsWord: false, convertedIsWord: false, perCharacter: -0.2)))
    }

    /// Unknown both ways, but the model is positively in favour — allowed. This
    /// is how inflected forms and names that are missing from the dictionary
    /// still get carried by a run.
    func testUnknownButModelFavoursConversionInherits() {
        XCTAssertTrue(WordChain.mayInherit(
            evidence(typedIsWord: false, convertedIsWord: false, perCharacter: 0.9)))
    }

    func testMarkingConvertedStopsRepeatWork() {
        var chain = WordChain()
        chain.append(entry(typed: "xnj"))
        chain.append(entry(typed: "yt"))
        chain.markConverted(count: 2)
        XCTAssertTrue(chain.retroactiveCandidates().isEmpty)
        XCTAssertTrue(chain.previousWasConverted)
    }
}
