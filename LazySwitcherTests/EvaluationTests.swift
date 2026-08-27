import Carbon.HIToolbox
import XCTest
@testable import Lazy_Switcher

/// Measures the detector on words it has never seen, through the shipping code.
///
/// Two decisions about method matter more than the numbers themselves.
///
/// **The corpus is held out at build time.** `build.py` puts 5% of every word
/// list aside and trains on the rest, so these words are absent from both the
/// dictionary and the n-gram tables. A model asked about a word it memorised
/// reports an accuracy that does not exist.
///
/// **The wrong-layout forms are produced by the real `KeyMapper`,** reading the
/// system's own layout data, not by a table written here. A fixture would test
/// the fixture.
///
/// The numbers this produces are the numbers, and where they disagree with
/// `03-ALGORITHM.md` the document is what changes: those tables were written
/// before any of this existed.
final class EvaluationTests: XCTestCase {

    private struct Corpus {
        let russian: [String]
        let english: [String]
    }

    private struct Tally {
        var convertedWhenItShould = 0
        var missedWhenItShould = 0
        var undecidedWhenItShould = 0
        var convertedWhenItShouldNot = 0      // ложное срабатывание — самое дорогое
        var keptWhenItShouldNot = 0
        var undecidedWhenItShouldNot = 0
        /// Misses caused specifically by both readings being real words — the
        /// case §6 of the algorithm proposes to settle with Zipf frequencies.
        var missedBecauseBothAreWords = 0
        var missedForOtherReasons = 0

        var shouldTotal: Int { convertedWhenItShould + missedWhenItShould + undecidedWhenItShould }
        var shouldNotTotal: Int { convertedWhenItShouldNot + keptWhenItShouldNot + undecidedWhenItShouldNot }
        var falsePositiveRate: Double {
            shouldNotTotal == 0 ? 0 : Double(convertedWhenItShouldNot) / Double(shouldNotTotal) * 100
        }
        var missRate: Double {
            shouldTotal == 0 ? 0 : Double(missedWhenItShould + undecidedWhenItShould) / Double(shouldTotal) * 100
        }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../LazySwitcherTests/EvaluationTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var russianModel: LanguageModel!
    private var englishModel: LanguageModel!
    private var mapper: KeyMapper!
    private var russianTable: KeyMapper.Table!
    private var englishTable: KeyMapper.Table!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundle = Bundle(for: type(of: self))
        func model(_ name: String) throws -> LanguageModel {
            guard let url = bundle.url(forResource: name, withExtension: "lsmodel")
                    ?? Bundle.main.url(forResource: name, withExtension: "lsmodel") else {
                throw XCTSkip("Нет модели \(name).lsmodel — соберите: ./Tools/build-models/all.sh")
            }
            return try LanguageModel(contentsOf: url)
        }
        russianModel = try model("ru")
        englishModel = try model("en")

        mapper = KeyMapper()
        russianTable = try table(forLanguage: "ru")
        englishTable = try table(forLanguage: "en")
    }

    private func table(forLanguage code: String) throws -> KeyMapper.Table {
        for source in InputSourceService.enabledKeyboardLayouts()
        where InputSourceService.primaryLanguage(of: source) == code {
            if let table = mapper.table(for: source) { return table }
        }
        throw XCTSkip("Раскладка «\(code)» не установлена")
    }

    private func corpus(_ name: String, limit: Int) throws -> [String] {
        let url = Self.repositoryRoot
            .appendingPathComponent("Tools/eval/corpus/\(name).heldout.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("Нет отложенного корпуса \(name) — соберите: ./Tools/build-models/all.sh")
        }
        let all = text.split(separator: "\n").map(String.init)
        guard all.count > limit else { return all }
        // Evenly spaced rather than the first N: the file is sorted, and the
        // first N would all begin with the same letter.
        let step = all.count / limit
        return stride(from: 0, to: all.count, by: step).map { all[$0] }
    }

    // MARK: - The measurement

    /// - Parameters:
    ///   - words: correctly typed words of `sourceLanguage`.
    ///   - shouldConvert: false — these are genuine words, touching them is a
    ///     false positive; true — these were typed on the wrong layout.
    private func measure(words: [String],
                         sourceTable: KeyMapper.Table,
                         otherTable: KeyMapper.Table,
                         sourceModel: LanguageModel,
                         otherModel: LanguageModel,
                         typedInWrongLayout: Bool) -> [Int: Tally] {
        let scorer = Scorer(models: .init(source: typedInWrongLayout ? otherModel : sourceModel,
                                          target: typedInWrongLayout ? sourceModel : otherModel))
        var byLength: [Int: Tally] = [:]

        for word in words {
            guard let keys = mapper.keystrokes(of: word, in: sourceTable) else { continue }
            // What is on screen, and what the other layout would have made of it.
            let onScreen = typedInWrongLayout ? mapper.render(keys, with: otherTable) : word
            let alternative = typedInWrongLayout ? word : mapper.render(keys, with: otherTable)
            guard let onScreen, let alternative else { continue }

            let (decision, evidence) = scorer.decide(typed: onScreen, converted: alternative)
            var tally = byLength[word.count] ?? Tally()
            if typedInWrongLayout {
                switch decision {
                case .convert: tally.convertedWhenItShould += 1
                case .keep: tally.missedWhenItShould += 1
                case .undecided: tally.undecidedWhenItShould += 1
                }
                if decision != .convert {
                    if evidence.typedIsKnownWord && evidence.convertedIsKnownWord {
                        tally.missedBecauseBothAreWords += 1
                    } else {
                        tally.missedForOtherReasons += 1
                    }
                }
            } else {
                switch decision {
                case .convert: tally.convertedWhenItShouldNot += 1
                case .keep: tally.keptWhenItShouldNot += 1
                case .undecided: tally.undecidedWhenItShouldNot += 1
                }
            }
            byLength[word.count] = tally
        }
        return byLength
    }

    private func merge(_ tallies: [[Int: Tally]]) -> [Int: Tally] {
        var result: [Int: Tally] = [:]
        for tally in tallies {
            for (length, value) in tally {
                var current = result[length] ?? Tally()
                current.convertedWhenItShould += value.convertedWhenItShould
                current.missedWhenItShould += value.missedWhenItShould
                current.undecidedWhenItShould += value.undecidedWhenItShould
                current.convertedWhenItShouldNot += value.convertedWhenItShouldNot
                current.keptWhenItShouldNot += value.keptWhenItShouldNot
                current.undecidedWhenItShouldNot += value.undecidedWhenItShouldNot
                current.missedBecauseBothAreWords += value.missedBecauseBothAreWords
                current.missedForOtherReasons += value.missedForOtherReasons
                result[length] = current
            }
        }
        return result
    }

    private func bucket(_ byLength: [Int: Tally], _ range: ClosedRange<Int>) -> Tally {
        merge([byLength.filter { range.contains($0.key) }])
            .values.reduce(into: Tally()) { total, value in
                total.convertedWhenItShould += value.convertedWhenItShould
                total.missedWhenItShould += value.missedWhenItShould
                total.undecidedWhenItShould += value.undecidedWhenItShould
                total.convertedWhenItShouldNot += value.convertedWhenItShouldNot
                total.keptWhenItShouldNot += value.keptWhenItShouldNot
                total.undecidedWhenItShouldNot += value.undecidedWhenItShouldNot
                total.missedBecauseBothAreWords += value.missedBecauseBothAreWords
                total.missedForOtherReasons += value.missedForOtherReasons
            }
    }

    // MARK: - Tests

    /// Focused check on short words, where the "both readings are real words"
    /// case actually lives.
    ///
    /// The main measurement samples the word list evenly, which under-represents
    /// short words badly — 44 two-letter words out of 25,000. That is far too
    /// thin to conclude anything about a case that is supposed to occur in three
    /// two-letter words out of five, so this takes every short word there is.
    func testShortWordsWhereBothReadingsAreRealWords() throws {
        let ru = try corpus("ru", limit: 1_000_000).filter { $0.count <= 5 }
        let en = try corpus("en", limit: 1_000_000).filter { $0.count <= 5 }
        XCTAssertGreaterThan(ru.count + en.count, 500, "Коротких слов слишком мало для вывода")

        let a = measure(words: ru, sourceTable: russianTable, otherTable: englishTable,
                        sourceModel: russianModel, otherModel: englishModel, typedInWrongLayout: true)
        let b = measure(words: en, sourceTable: englishTable, otherTable: russianTable,
                        sourceModel: englishModel, otherModel: russianModel, typedInWrongLayout: true)
        let all = merge([a, b])

        var lines = ["", "## Короткие слова: все, а не выборка", "",
                     "| длина | случаев | пропусков | из них оба слова настоящие |",
                     "|---|---|---|---|"]
        var totalCollisions = 0, totalMissed = 0
        for length in 1...5 {
            let t = bucket(all, length...length)
            let missed = t.missedBecauseBothAreWords + t.missedForOtherReasons
            totalCollisions += t.missedBecauseBothAreWords
            totalMissed += missed
            lines.append("| \(length) | \(t.shouldTotal) | \(missed) | \(t.missedBecauseBothAreWords) |")
        }
        lines.append("")
        lines.append("Пропусков \(totalMissed), из них из-за столкновения словарей \(totalCollisions).")
        let text = lines.joined(separator: "\n") + "\n"
        print(text)

        let url = Self.repositoryRoot.appendingPathComponent("eval/short-words.md")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Prints examples of what is still missed, so a weakness can be seen rather
    /// than inferred from a percentage.
    func testShowWhatIsStillMissed() throws {
        let words = try corpus("ru", limit: 4000).filter { $0.count >= 8 }
        let scorer = Scorer(models: .init(source: englishModel, target: russianModel))
        var unscorable: [(String, String)] = []
        var belowThreshold: [(String, String, Double)] = []

        for word in words {
            guard let keys = mapper.keystrokes(of: word, in: russianTable),
                  let latin = mapper.render(keys, with: englishTable) else { continue }
            let (decision, evidence) = scorer.decide(typed: latin, converted: word)
            guard decision != .convert else { continue }
            if !evidence.isScorable { unscorable.append((latin, word)) }
            else { belowThreshold.append((latin, word, evidence.perCharacter)) }
        }

        print("\nне поддаются оценке: \(unscorable.count)")
        for (latin, word) in unscorable.prefix(10) { print("   «\(latin)» → «\(word)»") }
        print("\nниже порога: \(belowThreshold.count)")
        for (latin, word, lambda) in belowThreshold.sorted(by: { $0.2 < $1.2 }).prefix(10) {
            print(String(format: "   Λ=%+.2f  «%@» → «%@»", lambda, latin, word))
        }
    }

    func testMeasureAndWriteReport() throws {
        let limit = 6000
        let russian = try corpus("ru", limit: limit)
        let english = try corpus("en", limit: limit)

        // Ложные срабатывания: настоящие слова, которые трогать нельзя.
        let falseRU = measure(words: russian, sourceTable: russianTable, otherTable: englishTable,
                              sourceModel: russianModel, otherModel: englishModel,
                              typedInWrongLayout: false)
        let falseEN = measure(words: english, sourceTable: englishTable, otherTable: russianTable,
                              sourceModel: englishModel, otherModel: russianModel,
                              typedInWrongLayout: false)
        // Пропуски: слова, набранные не в той раскладке.
        let missRU = measure(words: russian, sourceTable: russianTable, otherTable: englishTable,
                             sourceModel: russianModel, otherModel: englishModel,
                             typedInWrongLayout: true)
        let missEN = measure(words: english, sourceTable: englishTable, otherTable: russianTable,
                             sourceModel: englishModel, otherModel: russianModel,
                             typedInWrongLayout: true)

        let all = merge([falseRU, falseEN, missRU, missEN])
        var report = """
        # Замер детектора

        Слова отложены при сборке моделей и в обучении не участвовали.
        Формы «набрано не в той раскладке» получены настоящим `KeyMapper` из
        данных раскладок системы.

        Проверено слов: русских \(russian.count), английских \(english.count).

        | длина | ложных срабатываний | пропусков | слов |
        |---|---|---|---|

        """
        let buckets: [(String, ClosedRange<Int>)] = [
            ("1", 1...1), ("2", 2...2), ("3", 3...3), ("4", 4...4), ("5", 5...5),
            ("6", 6...6), ("7", 7...7), ("8+", 8...40),
            ("— 4–5", 4...5), ("— 6+", 6...40), ("— всего", 1...40),
        ]
        for (label, range) in buckets {
            let tally = bucket(all, range)
            guard tally.shouldTotal + tally.shouldNotTotal > 0 else { continue }
            report += String(format: "| %@ | %.2f%% | %.2f%% | %d |\n",
                             label, tally.falsePositiveRate, tally.missRate,
                             tally.shouldTotal + tally.shouldNotTotal)
        }

        let sixPlus = bucket(all, 6...40)
        let fourFive = bucket(all, 4...5)
        report += """

        ## Против критерия приёмки M5

        - от 6 символов, ложных срабатываний: **\(String(format: "%.2f%%", sixPlus.falsePositiveRate))** (требуется 0.00%)
        - 4–5 символов, ложных срабатываний: **\(String(format: "%.2f%%", fourFive.falsePositiveRate))** (требуется ≤ 0.30%)

        Пропуск здесь — это и `.keep`, и `.undecided`: неуверенность и есть
        пропуск, просто вежливый. Слово чинится хоткеем за полсекунды.

        """
        // What would Zipf frequencies actually buy? §6 of the algorithm proposes
        // them for the one case the dictionaries cannot settle: both readings
        // are real words. Worth knowing how big that case is before paying for
        // a frequency list, its licence and its attribution.
        report += "\n## Что упирается в «оба слова настоящие»\n\n"
        report += "| длина | пропусков всего | из них оба слова настоящие | доля |\n|---|---|---|---|\n"
        for (label, range) in buckets where !label.hasPrefix("—") {
            let t = bucket(all, range)
            let missed = t.missedBecauseBothAreWords + t.missedForOtherReasons
            guard missed > 0 else { continue }
            let share = Double(t.missedBecauseBothAreWords) / Double(missed) * 100
            report += String(format: "| %@ | %d | %d | %.1f%% |\n",
                             label, missed, t.missedBecauseBothAreWords, share)
        }
        let whole = bucket(all, 1...40)
        let allMissed = whole.missedBecauseBothAreWords + whole.missedForOtherReasons
        report += String(format: "\nВсего пропусков %d, из них по этой причине %d (%.1f%%).\n",
                         allMissed, whole.missedBecauseBothAreWords,
                         allMissed == 0 ? 0 : Double(whole.missedBecauseBothAreWords) / Double(allMissed) * 100)

        let url = Self.repositoryRoot.appendingPathComponent("eval/report.md")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? report.write(to: url, atomically: true, encoding: .utf8)
        print(report)

        XCTAssertGreaterThan(all.count, 0, "Замер не дал ни одной строки")
    }
}
