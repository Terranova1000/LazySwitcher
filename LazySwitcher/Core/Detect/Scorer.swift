import Foundation

/// Decides whether a word was typed in the wrong layout.
///
/// The task is narrower than it looks. QWERTY and ЙЦУКЕН map key *positions*
/// one to one, so the conversion loses nothing and there are no candidates to
/// generate: there are exactly two readings of what was typed, and we are
/// choosing between them.
///
/// The order of evidence is deliberate and is the opposite of what looks natural:
///
/// **The dictionary decides whenever it can. The model is the fallback for words
/// the dictionary does not know** — not an improvement layered on top of it.
/// A dictionary is never wrong about a word it knows; a smoothed n-gram model is
/// occasionally confidently wrong. Given that a false correction costs an order
/// of magnitude more than a miss, the exact answer goes first.
struct Scorer {

    struct Models {
        let source: LanguageModel        // язык, в раскладке которого печатали
        let target: LanguageModel        // язык другой раскладки
    }

    struct Evidence {
        /// Λ_total — log-likelihood ratio in nats, unnormalised.
        var logLikelihoodRatio: Double = 0
        /// Λ — the same divided by (length + 1), so one threshold fits all lengths.
        var perCharacter: Double = 0
        var typedIsKnownWord = false
        var convertedIsKnownWord = false
        var length = 0
        /// True when the dictionaries alone settle it.
        var decidedByDictionary = false
    }

    enum Decision: Equatable {
        case convert
        case keep
        /// Too close to call on its own; only a neighbour can settle it.
        case undecided
    }

    let models: Models

    // MARK: - Thresholds

    /// θ(L) = max(0, 12/L − 1.5), the closed form of the measured table.
    ///
    /// Clamping at zero is not cosmetic: without it the curve never actually
    /// reaches zero, while the measurements say the threshold is zero from eight
    /// characters on.
    static func threshold(forLength length: Int) -> Double {
        max(0, 12.0 / Double(length) - 1.5)
    }

    /// Below this, a word never decides its own fate. Every one-character word
    /// collides with a real word of the other language, and three in five
    /// two-character ones do.
    static let minimumSelfDecidingLength = 3

    // MARK: - Scoring

    func evidence(typed: String, converted: String) -> Evidence {
        var evidence = Evidence()
        evidence.length = typed.count

        evidence.typedIsKnownWord = models.source.contains(typed)
        evidence.convertedIsKnownWord = models.target.contains(converted)

        let typedScore = models.source.logProbability(of: typed) ?? -Double.infinity
        let convertedScore = models.target.logProbability(of: converted) ?? -Double.infinity
        evidence.logLikelihoodRatio = convertedScore - typedScore
        evidence.perCharacter = evidence.logLikelihoodRatio / Double(evidence.length + 1)

        evidence.decidedByDictionary = evidence.typedIsKnownWord != evidence.convertedIsKnownWord
        return evidence
    }

    func decide(typed: String, converted: String) -> (Decision, Evidence) {
        let evidence = evidence(typed: typed, converted: converted)
        return (decide(evidence), evidence)
    }

    func decide(_ evidence: Evidence) -> Decision {
        guard evidence.length > 0 else { return .keep }

        // The dictionary, when it has an opinion, is the whole answer.
        if evidence.typedIsKnownWord && !evidence.convertedIsKnownWord { return .keep }
        if !evidence.typedIsKnownWord && evidence.convertedIsKnownWord {
            // Even here, a very short word is not allowed to decide alone: "yt"
            // is "не" and also a plausible fragment, and both readings exist.
            return evidence.length >= Self.minimumSelfDecidingLength ? .convert : .undecided
        }

        // Both known, or neither. Now the model gets to speak, against a
        // threshold that rises as the word gets shorter.
        if evidence.typedIsKnownWord && evidence.convertedIsKnownWord {
            // Both are real words. Nothing but context can settle this, and
            // guessing here is precisely how "gel" becomes "пуд".
            return .undecided
        }

        guard evidence.length >= Self.minimumSelfDecidingLength else { return .undecided }
        let threshold = Self.threshold(forLength: evidence.length)
        if evidence.perCharacter > threshold { return .convert }
        if evidence.perCharacter < -threshold { return .keep }
        return .undecided
    }

    // MARK: - Context

    /// Weighted mean of Λ over a window of words.
    ///
    /// The weight is `length + 1` because that is what each Λ was divided by, so
    /// this is a mean of the same quantity rather than a mean of a similar one.
    /// Two words are enough: from six characters the two languages stop
    /// colliding entirely, so all the difficulty is in short words, and one
    /// neighbour resolves nearly all of it.
    static func windowScore(_ items: [Evidence]) -> Double {
        let weights = items.reduce(0.0) { $0 + Double($1.length + 1) }
        guard weights > 0 else { return 0 }
        let total = items.reduce(0.0) { $0 + Double($1.length + 1) * $1.perCharacter }
        return total / weights
    }
}
