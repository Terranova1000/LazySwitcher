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
                       functionWord: Bool = false,
                       evidence e: Scorer.Evidence? = nil) -> WordChain.Entry {
        .init(typed: typed, alternative: alternative,
              convertedIsFunctionWord: functionWord, typedIsFunctionWord: false,
              separator: separator,
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
        XCTAssertTrue(WordChain.mayInherit(evidence(typedIsWord: false, convertedIsWord: true),
                                           isFunctionWord: false, typedLength: 3))
    }

    func testARealWordDoesNotInherit() {
        XCTAssertFalse(WordChain.mayInherit(evidence(typedIsWord: true, convertedIsWord: false),
                                            isFunctionWord: false, typedLength: 3),
                       "Настоящее слово не должно менять себя за компанию с соседом")
    }

    func testGibberishDoesNotInherit() {
        XCTAssertFalse(WordChain.mayInherit(
            evidence(typedIsWord: false, convertedIsWord: false, perCharacter: -0.2),
            isFunctionWord: false, typedLength: 4))
    }

    /// Unknown both ways is no longer enough, however confident the model is.
    ///
    /// This is the `pwa` case, reported from real use: typing «pwa ghbkj;tybt»
    /// should leave the abbreviation alone and fix only the word after it. But
    /// `pwa` converts to `зцф`, which is not a word in any sense — and the model
    /// still rated it more Russian-looking than `pwa` is English-looking, so the
    /// abbreviation was dragged along. Being a word is a fact; looking like one
    /// is not, and only the fact is allowed to move somebody's text.
    func testAbbreviationIsNotSweptEvenWhenTheModelLikesIt() {
        XCTAssertFalse(WordChain.mayInherit(
            evidence(typedIsWord: false, convertedIsWord: false, perCharacter: 0.9),
            isFunctionWord: false, typedLength: 3),
            "«pwa» обязано остаться аббревиатурой")

        var chain = WordChain()
        chain.append(entry(typed: "pwa", alternative: "зцф",
                           evidence: evidence(typedIsWord: false, convertedIsWord: false,
                                              perCharacter: 0.9)))
        XCTAssertTrue(chain.retroactiveCandidates().isEmpty)
    }

    /// A grammar word is carried, because it is on a list somebody wrote down —
    /// which is a fact about the language, not a guess about a probability.
    func testFunctionWordIsCarried() {
        XCTAssertTrue(WordChain.mayInherit(
            evidence(typedIsWord: false, convertedIsWord: false),
            isFunctionWord: true, typedLength: 3))
    }

    func testMarkingConvertedStopsRepeatWork() {
        var chain = WordChain()
        chain.append(entry(typed: "xnj"))
        chain.append(entry(typed: "yt"))
        chain.markConverted(count: 2, endingAt: 2)
        XCTAssertTrue(chain.retroactiveCandidates().isEmpty)
        XCTAssertTrue(chain.previousWasConverted)
    }
}


/// Runs of short words, which is what a Russian sentence mostly is.
final class ShortWordRunTests: XCTestCase {

    private func evidence(typedIsWord: Bool, convertedIsWord: Bool,
                          length: Int) -> Scorer.Evidence {
        var e = Scorer.Evidence()
        e.typedIsKnownWord = typedIsWord
        e.convertedIsKnownWord = convertedIsWord
        e.length = length
        return e
    }

    private func entry(_ typed: String, _ alternative: String,
                       functionWord: Bool = true, typedIsWord: Bool = false,
                       typedIsFunctionWord: Bool = false) -> WordChain.Entry {
        .init(typed: typed, alternative: alternative,
              convertedIsFunctionWord: functionWord, typedIsFunctionWord: typedIsFunctionWord,
              separator: " ",
              evidence: evidence(typedIsWord: typedIsWord, convertedIsWord: false,
                                 length: typed.count),
              converted: false)
    }

    /// «о нём» typed on a Latin layout. Neither word is long enough to act on
    /// alone, and neither has a long neighbour to be rescued by — together they
    /// are four characters of evidence.
    func testTwoShortGrammarWordsAccumulate() {
        var chain = WordChain()
        chain.append(entry("j", "о"))
        chain.append(entry("ytv", "нем"))
        let run = chain.pendingRun()
        XCTAssertEqual(run.map(\.typed), ["j", "ytv"])
        XCTAssertEqual(WordChain.combinedLength(run), 5, "1 + 3 символа и пробел между ними")
    }

    /// An abbreviation breaks the run rather than joining it.
    func testAbbreviationBreaksTheRun() {
        var chain = WordChain()
        chain.append(entry("j", "о"))
        chain.append(entry("pwa", "зцф", functionWord: false))
        XCTAssertTrue(chain.pendingRun().isEmpty,
                      "Аббревиатура обрывает цепочку, а не тянется вместе с ней")
    }

    /// A genuine English word breaks it too — that is the guard that keeps an
    /// English sentence from being converted word by word.
    func testRealSourceWordBreaksTheRun() {
        var chain = WordChain()
        chain.append(entry("j", "о"))
        chain.append(entry("the", "енщ", functionWord: false, typedIsWord: true))
        XCTAssertTrue(chain.pendingRun().isEmpty)
    }

    func testRunIsBounded() {
        var chain = WordChain()
        for _ in 0..<6 { chain.append(entry("j", "о")) }
        XCTAssertLessThanOrEqual(chain.pendingRun().count, WordChain.maximumLookback)
    }
}

/// The curated grammar-word lists.
final class FunctionWordTests: XCTestCase {

    /// The words the user named, plus the ones that appear in every sentence.
    func testCommonRussianGrammarWordsArePresent() {
        for word in ["то", "а", "о", "нем", "нём", "том", "это", "в", "и", "не",
                     "на", "с", "по", "для", "что", "как", "его", "их"] {
            XCTAssertTrue(FunctionWords.contains(word, language: "ru"), "нет «\(word)»")
        }
    }

    func testCommonEnglishGrammarWordsArePresent() {
        for word in ["a", "an", "the", "of", "to", "in", "is", "it", "and", "for"] {
            XCTAssertTrue(FunctionWords.contains(word, language: "en"), "нет «\(word)»")
        }
    }

    /// Nothing that could be somebody's abbreviation or initials.
    func testNoAmbiguousEntries() {
        for word in ["зцф", "pwa", "api", "sql", "usb", "рот", "код"] {
            XCTAssertFalse(FunctionWords.contains(word, language: "ru"), "лишнее: «\(word)»")
            XCTAssertFalse(FunctionWords.contains(word, language: "en"), "лишнее: «\(word)»")
        }
    }

    func testLookupIgnoresCase() {
        XCTAssertTrue(FunctionWords.contains("ЭТО", language: "ru"))
        XCTAssertTrue(FunctionWords.contains("The", language: "en"))
    }

    /// The declared maximum is used to skip lookups, so it has to be true.
    func testMaximumLengthIsHonest() {
        for word in FunctionWords.russian.union(FunctionWords.english) {
            XCTAssertLessThanOrEqual(word.count, FunctionWords.maximumLength,
                                     "«\(word)» длиннее заявленного максимума")
        }
    }
}


/// One-letter words, where the dictionaries are useless.
///
/// SCOWL lists every letter of the alphabet as an English word, and the Russian
/// dictionary does the same for Cyrillic. So "the typed reading is a real word"
/// is true for every single character and carries no information — while
/// blocking exactly the one-letter prepositions somebody typing Russian on a
/// Latin layout most wants fixed: о, и, в, с, у, к, я.
final class SingleLetterTests: XCTestCase {

    private func entry(_ typed: String, _ alternative: String,
                       convertedIsFunction: Bool, typedIsFunction: Bool) -> WordChain.Entry {
        var e = Scorer.Evidence()
        e.typedIsKnownWord = true          // словарь говорит «да» про любую букву
        e.convertedIsKnownWord = true
        e.length = typed.count
        return .init(typed: typed, alternative: alternative,
                     convertedIsFunctionWord: convertedIsFunction,
                     typedIsFunctionWord: typedIsFunction,
                     separator: " ", evidence: e, converted: false)
    }

    /// «j» → «о». Not an English grammar word, is a Russian one: carried.
    func testLatinLetterMappingToARussianPrepositionIsCarried() {
        let e = entry("j", "о", convertedIsFunction: true, typedIsFunction: false)
        XCTAssertFalse(WordChain.blocksSweep(e))
        XCTAssertTrue(WordChain.isCandidate(e))
    }

    /// «a» is an English word in the sense that matters, and stays put even
    /// though the dictionary says the same thing about both readings.
    func testEnglishArticleIsProtected() {
        let e = entry("a", "ф", convertedIsFunction: false, typedIsFunction: true)
        XCTAssertTrue(WordChain.blocksSweep(e))
        XCTAssertFalse(WordChain.isCandidate(e))
    }

    func testEnglishPronounIsProtected() {
        let e = entry("i", "ш", convertedIsFunction: false, typedIsFunction: true)
        XCTAssertFalse(WordChain.isCandidate(e))
    }

    /// The same in reverse: genuine Russian «и» is not turned into «b».
    func testRussianConjunctionIsProtected() {
        let e = entry("и", "b", convertedIsFunction: false, typedIsFunction: true)
        XCTAssertTrue(WordChain.blocksSweep(e))
        XCTAssertFalse(WordChain.isCandidate(e))
    }

    /// «ф» → «a»: typing an English article on ЙЦУКЕН comes back.
    func testCyrillicLetterMappingToAnEnglishArticleIsCarried() {
        let e = entry("ф", "a", convertedIsFunction: true, typedIsFunction: false)
        XCTAssertTrue(WordChain.isCandidate(e))
    }

    /// Longer words keep using the dictionary — it is informative there.
    func testLongerWordsStillUseTheDictionary() {
        var e = Scorer.Evidence()
        e.typedIsKnownWord = true
        e.length = 4
        let entry = WordChain.Entry(typed: "hell", alternative: "руды",
                                    convertedIsFunctionWord: false, typedIsFunctionWord: false,
                                    separator: " ", evidence: e, converted: false)
        XCTAssertTrue(WordChain.blocksSweep(entry))
    }
}
