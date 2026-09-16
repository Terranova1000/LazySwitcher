import Foundation

/// Where a word really ends, when its last keys are punctuation in the layout
/// it was typed in and letters in the other one.
///
/// On the Latin layout `.` `,` `;` are the Cyrillic ю, б, ж. So `ghbdtn.` is
/// «привет» and a full stop, while `cdj.` is «свою» — the same kind of
/// keystroke, and only the words can tell them apart. The key buffer cannot
/// decide this when the key is pressed, so the word is kept whole there and
/// the question is settled here, once the word has ended.
///
/// The dictionary answers first, as everywhere else in the detector:
///   · the whole thing is a word in the other language → the mark was a letter;
///   · without the mark it is a word, in either language → it was punctuation.
/// Only when neither reading is a known word does the model choose, taking
/// the one that looks more like its language. Measured on held-out words that
/// no dictionary knows: right in 96% of words genuinely ending in б/ю/ж, and in
/// 99% of words followed by a full stop or a comma.
enum WordEnding {

    struct Reading: Equatable {
        /// The word as it is on screen now, without trailing punctuation.
        let typed: String
        /// What the same keys mean in the other layout.
        let alternative: String
        /// Punctuation after the word, to be left exactly as typed. Empty when
        /// there is none.
        let marks: String
    }

    /// - Parameter scorer: models for the typed layout's language (source) and
    ///   the other one (target). Without one, trailing marks are treated as
    ///   punctuation — the far more common case.
    static func resolve(_ keys: [KeyRecord], mapper: KeyMapper,
                        source: KeyMapper.Table, target: KeyMapper.Table,
                        scorer: Scorer?) -> Reading? {
        guard let typed = mapper.render(keys, with: source),
              let alternative = mapper.render(keys, with: target) else { return nil }
        let whole = Reading(typed: typed, alternative: alternative, marks: "")

        let count = mapper.ambiguousTrailingMarks(keys, source: source, other: target)
        // A word made of nothing but such keys is a word of those letters.
        guard count > 0, count < keys.count else { return whole }
        let core = Array(keys.dropLast(count))
        guard let coreTyped = mapper.render(core, with: source),
              let coreAlternative = mapper.render(core, with: target),
              let marks = mapper.render(Array(keys.suffix(count)), with: source)
        else { return whole }
        let stripped = Reading(typed: coreTyped, alternative: coreAlternative, marks: marks)

        guard let scorer else { return stripped }
        return choose(whole: whole, stripped: stripped, scorer: scorer)
    }

    static func choose(whole: Reading, stripped: Reading, scorer: Scorer) -> Reading {
        let wholeEvidence = scorer.evidence(typed: whole.typed, converted: whole.alternative)
        if wholeEvidence.convertedIsKnownWord { return whole }

        let strippedEvidence = scorer.evidence(typed: stripped.typed, converted: stripped.alternative)
        if strippedEvidence.convertedIsKnownWord || strippedEvidence.typedIsKnownWord { return stripped }
        if wholeEvidence.typedIsKnownWord { return whole }

        let wholeConverts = scorer.decide(wholeEvidence) == .convert
        let strippedConverts = scorer.decide(strippedEvidence) == .convert
        switch (wholeConverts, strippedConverts) {
        case (true, false):
            return whole
        case (true, true) where wholeEvidence.convertedPlausibility > strippedEvidence.convertedPlausibility:
            return whole
        default:
            return stripped
        }
    }
}
