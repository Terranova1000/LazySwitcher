import Carbon.HIToolbox
import XCTest
@testable import Lazy_Switcher

/// The rules users actually notice, tested on real sentences.
///
/// Each case here came from somebody typing and telling us it was wrong. They
/// run against the shipping models and the shipping layout tables, so a "pass"
/// means the product behaves this way — not that a mock does.
final class CorrectionPlannerTests: XCTestCase {

    private var planner: CorrectionPlanner!
    private var mapper: KeyMapper!
    private var latin: KeyMapper.Table!
    private var cyrillic: KeyMapper.Table!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundle = Bundle(for: AppDelegate.self)
        func model(_ name: String) throws -> LanguageModel {
            guard let url = bundle.url(forResource: name, withExtension: "lsmodel") else {
                throw XCTSkip("Нет модели \(name).lsmodel")
            }
            return try LanguageModel(contentsOf: url)
        }
        planner = CorrectionPlanner(scorer: Scorer(models: .init(source: try model("en"),
                                                                target: try model("ru"))))
        mapper = KeyMapper()
        latin = try table("en")
        cyrillic = try table("ru")
    }

    private func table(_ code: String) throws -> KeyMapper.Table {
        for source in InputSourceService.enabledKeyboardLayouts()
        where InputSourceService.primaryLanguage(of: source) == code {
            if let t = mapper.table(for: source) { return t }
        }
        throw XCTSkip("Раскладка «\(code)» не установлена")
    }

    /// Types a Latin sentence and returns what happened to each word.
    ///
    /// The Latin form is produced from the Russian one through the real layout
    /// tables, exactly as a person mistyping would produce it.
    private func run(_ latinSentence: String, minimum: Int = 5) -> [(String, CorrectionPlanner.Plan)] {
        var chain = WordChain()
        var result: [(String, CorrectionPlanner.Plan)] = []
        for word in latinSentence.split(separator: " ").map(String.init) {
            guard let keys = mapper.keystrokes(of: word, in: latin),
                  let alternative = mapper.render(keys, with: cyrillic) else { continue }
            let input = CorrectionPlanner.Input(typed: word, alternative: alternative,
                                                sourceLanguage: "en", targetLanguage: "ru",
                                                minimumLength: minimum)
            let (plan, _, entry) = planner.plan(input, chain: chain)
            chain.append(entry)
            if case .convert(let carrying, _) = plan {
                chain.markConverted(count: carrying + 1)
            }
            result.append((word, plan))
        }
        return result
    }

    /// Which words end up in the other alphabet.
    ///
    /// A word's own plan is not the whole answer: `wait` often means "the next
    /// word will take me with it", and `carrying: N` says how many words to the
    /// left went along. Counting only the plans marked `convert` reports a
    /// sentence as half-fixed when it was fixed entirely — which is what the
    /// first version of this helper did.
    private func converted(_ plans: [(String, CorrectionPlanner.Plan)]) -> [String] {
        var changed = Set<Int>()
        for (index, entry) in plans.enumerated() {
            guard case .convert(let carrying, _) = entry.1 else { continue }
            changed.insert(index)
            for back in 1...max(carrying, 1) where carrying > 0 && index - back >= 0 {
                changed.insert(index - back)
            }
        }
        return changed.sorted().map { plans[$0].0 }
    }

    // MARK: - Сообщённое пользователем

    /// «я установил pwa ghbkj;tybt»: the abbreviation stays, the word after it
    /// is fixed. Reported from real use — `pwa` was being dragged along.
    func testAbbreviationSurvivesWhileTheWordAfterItIsFixed() {
        let plans = run("pwa ghbkj;tybt")
        XCTAssertEqual(plans[0].1, .keep, "«pwa» обязано остаться аббревиатурой")
        guard case .convert(let carrying, _) = plans[1].1 else {
            return XCTFail("«ghbkj;tybt» должно исправиться, получили \(plans[1].1)")
        }
        XCTAssertEqual(carrying, 0, "и не тянуть «pwa» за собой")
    }

    /// «о нём» — two grammar words, neither long enough alone, no long word to
    /// rescue them. Together they are enough.
    func testRunOfShortGrammarWordsConverts() {
        let plans = run("j ytv")
        XCTAssertEqual(plans[0].1, .wait, "первое слово ждёт")
        guard case .convert(let carrying, let reason) = plans[1].1 else {
            return XCTFail("пара «j ytv» должна исправиться, получили \(plans[1].1)")
        }
        XCTAssertEqual(reason, .run)
        XCTAssertEqual(carrying, 1, "вместе со словом слева")
    }

    /// A long word rescues the short ones before it.
    func testLongWordRescuesShortOnesBeforeIt() {
        let plans = run("b j ghbkj;tybt")
        guard case .convert(let carrying, _) = plans[2].1 else {
            return XCTFail("длинное слово должно исправиться")
        }
        XCTAssertEqual(carrying, 2, "и забрать «b» и «j» с собой")
    }

    /// A whole sentence of Russian typed on a Latin layout.
    func testEntireSentenceIsFixed() {
        let plans = run("'nj ntcnjdjt ghtlkj;tybt lkz ghjdthrb")
        let fixed = Set(converted(plans))
        let missed = plans.map(\.0).filter { !fixed.contains($0) }
        XCTAssertTrue(missed.isEmpty, "не исправлены: " + missed.joined(separator: ", "))
    }

    // MARK: - Чего трогать нельзя

    /// Genuine English is left alone — this is the case that costs trust.
    func testGenuineEnglishIsUntouched() {
        for sentence in ["the quick brown fox jumps",
                         "i have a small problem with this",
                         "we should be able to fix it"] {
            let plans = run(sentence)
            XCTAssertTrue(converted(plans).isEmpty,
                          "«\(sentence)» — настоящий английский, тронуто: \(converted(plans))")
        }
    }

    /// English grammar words next to a converted word still do not follow it.
    func testEnglishArticlesResistANeighbour() {
        let plans = run("a ghbkj;tybt")
        XCTAssertEqual(plans[0].1, .keep, "английский артикль не идёт за соседом")
    }

    func testAbbreviationsOfSeveralKindsSurvive() {
        for word in ["pwa", "api", "sql", "usb", "css"] {
            let plans = run("\(word) ghbkj;tybt")
            XCTAssertEqual(plans[0].1, .keep, "«\(word)» обязано остаться")
        }
    }
}

/// Cases reported from a week of real use.
final class ReportedCasesTests: XCTestCase {

    private var planner: CorrectionPlanner!
    private var mapper: KeyMapper!
    private var latin: KeyMapper.Table!
    private var cyrillic: KeyMapper.Table!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundle = Bundle(for: AppDelegate.self)
        func model(_ name: String) throws -> LanguageModel {
            guard let url = bundle.url(forResource: name, withExtension: "lsmodel") else {
                throw XCTSkip("Нет модели \(name).lsmodel")
            }
            return try LanguageModel(contentsOf: url)
        }
        planner = CorrectionPlanner(scorer: Scorer(models: .init(source: try model("en"),
                                                                target: try model("ru"))))
        mapper = KeyMapper()
        for source in InputSourceService.enabledKeyboardLayouts() {
            switch InputSourceService.primaryLanguage(of: source) {
            case "en": latin = mapper.table(for: source)
            case "ru": cyrillic = mapper.table(for: source)
            default: break
            }
        }
        try XCTSkipIf(latin == nil || cyrillic == nil, "Нужны обе раскладки")
    }

    private func run(_ sentence: String, minimum: Int = 5) -> [(String, CorrectionPlanner.Plan)] {
        var chain = WordChain()
        var result: [(String, CorrectionPlanner.Plan)] = []
        for word in sentence.split(separator: " ").map(String.init) {
            guard let keys = mapper.keystrokes(of: word, in: latin),
                  let alternative = mapper.render(keys, with: cyrillic) else { continue }
            let (plan, _, entry) = planner.plan(
                .init(typed: word, alternative: alternative, sourceLanguage: "en",
                      targetLanguage: "ru", minimumLength: minimum), chain: chain)
            chain.append(entry)
            if case .convert(let carrying, _) = plan { chain.markConverted(count: carrying + 1) }
            result.append((word, plan))
        }
        return result
    }

    private func didConvert(_ plan: CorrectionPlanner.Plan) -> Bool {
        if case .convert = plan { return true }
        return false
    }

    /// Hyphenated words. Hunspell has no hyphenated entries at all, so the whole
    /// word was unknown while every part of it was known — and the model could
    /// not represent the hyphen either, so it returned "no opinion" and the word
    /// stayed in Latin.
    func testHyphenatedWordsConvert() {
        for (latinForm, russian) in [("gjxtve-nj", "почему-то"),
                                     ("rfrbt-yb,elm", "какие-нибудь"),
                                     ("rjuj-nj", "кого-то"),
                                     ("gj-vjtve", "по-моему")] {
            let plans = run(latinForm)
            XCTAssertTrue(didConvert(plans[0].1),
                          "«\(latinForm)» → «\(russian)» должно исправляться, получили \(plans[0].1)")
        }
    }

    /// A hyphen is not automatically kebab-case any more, but two of them still
    /// are, and so is one next to a digit.
    func testIdentifiersWithHyphensAreStillRefused() {
        let context = HotContext(isSecureInput: false, policy: .automatic, fieldRole: .text)
        for word in ["kebab-case-name", "utf-8", "ipv-4", "-leading", "trailing-"] {
            XCTAssertNotEqual(VetoGate.evaluate(.init(word: word, context: context)), .allowed,
                              "«\(word)» обязано быть отвергнуто")
        }
    }

    /// «yt» → «не». The English dictionary lists `yt` as a word — it lists 349
    /// two-letter combinations — so the guard that protects genuine words was
    /// blocking exactly the ones that needed converting.
    func testTwoLetterWordsAreCarriedByANeighbour() {
        let plans = run("yt ghbkj;tybt")
        XCTAssertEqual(plans[0].1, .wait, "«yt» ждёт соседа")
        guard case .convert(let carrying, _) = plans[1].1 else {
            return XCTFail("длинное слово должно исправиться")
        }
        XCTAssertEqual(carrying, 1, "и забрать «yt» с собой")
    }

    func testTwoLetterRunConvertsTogether() {
        let plans = run("yt nj")
        XCTAssertTrue(didConvert(plans[1].1), "«yt nj» → «не то» должно исправляться парой")
    }

    /// And genuine English two-letter words still resist.
    func testEnglishTwoLetterWordsResist() {
        for word in ["no", "it", "if", "in", "at", "on", "is", "as", "an", "of", "to", "we", "he"] {
            let plans = run("\(word) ghbkj;tybt")
            XCTAssertEqual(plans[0].1, .keep,
                           "«\(word)» — английское слово, трогать нельзя")
        }
    }
}
