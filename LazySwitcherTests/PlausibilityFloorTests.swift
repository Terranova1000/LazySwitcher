import Carbon.HIToolbox
import XCTest
@testable import Lazy_Switcher

/// Better than what is on screen is not the same as a word.
///
/// With every keystroke delivered twice, `сообщение` became
/// `ссооооббщщееннииее`, and its Latin reading `ccjjjj,,oottyybbtt` scored
/// better — so it went on screen. Both readings were nonsense; the model was
/// only ever asked which was less so.
final class PlausibilityFloorTests: XCTestCase {

    private var russian: LanguageModel!
    private var english: LanguageModel!
    private var mapper: KeyMapper!
    private var ruTable: KeyMapper.Table!
    private var enTable: KeyMapper.Table!

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundle = Bundle(for: AppDelegate.self)
        func model(_ name: String) throws -> LanguageModel {
            guard let url = bundle.url(forResource: name, withExtension: "lsmodel") else {
                throw XCTSkip("Нет модели \(name).lsmodel")
            }
            return try LanguageModel(contentsOf: url)
        }
        russian = try model("ru")
        english = try model("en")
        mapper = KeyMapper()
        ruTable = try table("ru")
        enTable = try table("en")
    }

    private func table(_ code: String) throws -> KeyMapper.Table {
        for source in InputSourceService.enabledKeyboardLayouts()
        where InputSourceService.primaryLanguage(of: source) == code {
            if let table = mapper.table(for: source) { return table }
        }
        throw XCTSkip("Раскладка «\(code)» не установлена")
    }

    /// Both readings of `word` with every key pressed twice.
    private func doubled(_ word: String, own: KeyMapper.Table,
                         other: KeyMapper.Table) -> (typed: String, alternative: String)? {
        guard let keys = mapper.keystrokes(of: word, in: own) else { return nil }
        let twice = keys.flatMap { [$0, $0] }
        guard let typed = mapper.render(twice, with: own),
              let alternative = mapper.render(twice, with: other) else { return nil }
        return (typed, alternative)
    }

    func testTheReportedWordIsLeftAlone() throws {
        let scorer = Scorer(models: .init(source: russian, target: english))
        let readings = try XCTUnwrap(doubled("сообщение", own: ruTable, other: enTable))
        XCTAssertEqual(readings.typed, "ссооооббщщееннииее")
        XCTAssertEqual(readings.alternative, "ccjjjj,,oottyybbtt")

        let (decision, evidence) = scorer.decide(typed: readings.typed, converted: readings.alternative)
        XCTAssertNotEqual(decision, .convert)
        // And it is the floor that says no: by the ratio alone this converts.
        XCTAssertGreaterThan(evidence.perCharacter, Scorer.threshold(forLength: evidence.length))
        XCTAssertLessThan(evidence.convertedPlausibility, Scorer.plausibilityFloor)
    }

    /// Ordinary corrections do not come anywhere near it.
    func testRealCorrectionsStillHappen() {
        let scorer = Scorer(models: .init(source: english, target: russian))
        for (typed, converted) in [("ghbdtn", "привет"), ("cjj,otybt", "сообщение"),
                                   ("gjkmpjdfntkm", "пользователь"), ("ytljhjpevtybt", "недоразумение")] {
            XCTAssertEqual(scorer.decide(typed: typed, converted: converted).0, .convert, typed)
        }
        let back = Scorer(models: .init(source: russian, target: english))
        for (typed, converted) in [("руддщ", "hello"), ("штащкьфешщт", "information")] {
            XCTAssertEqual(back.decide(typed: typed, converted: converted).0, .convert, typed)
        }
    }

    /// The measurement behind the constant, kept as a test.
    ///
    /// A model rebuilt from different data moves plausibility around, and the
    /// floor was chosen against these numbers. If that happens, this is where
    /// it should show up — not in somebody's text.
    func testOnHeldOutWordsTheFloorCostsAlmostNothingAndStopsDoubledNonsense() throws {
        struct Side { let name: String; let own: KeyMapper.Table; let other: KeyMapper.Table
                      let ownModel: LanguageModel; let otherModel: LanguageModel }
        let sides = [Side(name: "ru", own: ruTable, other: enTable, ownModel: russian, otherModel: english),
                     Side(name: "en", own: enTable, other: ruTable, ownModel: english, otherModel: russian)]

        var byModel = 0, lostToFloor = 0
        var doubledWouldConvert = 0, doubledStopped = 0
        for side in sides {
            let words = try corpus(side.name, limit: 6000)
            let wrongLayout = Scorer(models: .init(source: side.otherModel, target: side.ownModel))
            let rightLayout = Scorer(models: .init(source: side.ownModel, target: side.otherModel))
            for word in words {
                // Typed in the wrong layout: the correction the floor must not cost.
                if let keys = mapper.keystrokes(of: word, in: side.own),
                   let typed = mapper.render(keys, with: side.other) {
                    let evidence = wrongLayout.evidence(typed: typed, converted: word)
                    if evidence.isScorable, !evidence.typedIsKnownWord, !evidence.convertedIsKnownWord,
                       evidence.length >= Scorer.minimumSelfDecidingLength,
                       evidence.perCharacter > Scorer.threshold(forLength: evidence.length) {
                        byModel += 1
                        if wrongLayout.decide(evidence) != .convert { lostToFloor += 1 }
                    }
                }
                // Typed correctly, delivered twice: the damage the floor must stop.
                if let readings = doubled(word, own: side.own, other: side.other) {
                    let evidence = rightLayout.evidence(typed: readings.typed, converted: readings.alternative)
                    if evidence.isScorable, !evidence.typedIsKnownWord, !evidence.convertedIsKnownWord,
                       evidence.perCharacter > Scorer.threshold(forLength: evidence.length) {
                        doubledWouldConvert += 1
                        if rightLayout.decide(evidence) != .convert { doubledStopped += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(byModel, 5000, "Слишком мало слов для вывода")
        XCTAssertGreaterThan(doubledWouldConvert, 3000, "Слишком мало слов для вывода")
        let lostShare = Double(lostToFloor) / Double(byModel) * 100
        let stoppedShare = Double(doubledStopped) / Double(doubledWouldConvert) * 100
        print(String(format: "порог %.1f: потеряно верных исправлений %d из %d (%.3f%%), "
                     + "остановлено удвоенной бессмыслицы %d из %d (%.2f%%)",
                     Scorer.plausibilityFloor, lostToFloor, byModel, lostShare,
                     doubledStopped, doubledWouldConvert, stoppedShare))
        // 0.18% when the floor was chosen; the English list, being mostly
        // names and abbreviations, loses a little more than the Russian one.
        XCTAssertLessThanOrEqual(lostShare, 0.3)
        XCTAssertGreaterThanOrEqual(stoppedShare, 99.9)
    }

    private func corpus(_ name: String, limit: Int) throws -> [String] {
        let url = Self.repositoryRoot.appendingPathComponent("Tools/eval/corpus/\(name).heldout.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("Нет отложенного корпуса \(name)")
        }
        let all = text.split(separator: "\n").map(String.init)
        guard all.count > limit else { return all }
        let step = all.count / limit
        return stride(from: 0, to: all.count, by: step).map { all[$0] }
    }
}
