import Foundation

/// Decides what to do with a word that has just been finished.
///
/// Pulled out of `AppDelegate` so it can be tested without a keyboard, a window
/// or a focused application. That mattered more than tidiness: the rules here
/// are the ones users notice — why `pwa` survived, why `о нём` did not get
/// fixed — and verifying them through the interface meant driving Safari and
/// reading text back out, which was slow and, worse, flaky enough that a real
/// defect and a mis-aimed test looked identical.
struct CorrectionPlanner {

    struct Input {
        /// What is on screen now.
        let typed: String
        /// What the same keys mean in the other layout.
        let alternative: String
        let sourceLanguage: String
        let targetLanguage: String
        /// Shortest word we will convert on its own.
        let minimumLength: Int
    }

    enum Plan: Equatable {
        /// Replace this word, together with `carrying` words before it.
        case convert(carrying: Int, reason: Reason)
        /// Leave it, and remember it — a later word may carry it.
        case wait
        /// Leave it, and it is not eligible to be carried either.
        case keep
    }

    enum Reason: String, Equatable {
        /// Long enough to decide for itself.
        case ownEvidence
        /// The word before it was converted.
        case neighbour
        /// Enough short words have piled up together.
        case run
    }

    let scorer: Scorer

    func plan(_ input: Input, chain: WordChain) -> (Plan, Scorer.Evidence, WordChain.Entry) {
        let (decision, evidence) = scorer.decide(typed: input.typed, converted: input.alternative)

        let convertedIsFunction = input.alternative.count <= FunctionWords.maximumLength
            && FunctionWords.contains(input.alternative, language: input.targetLanguage)
        let typedIsFunction = input.typed.count <= FunctionWords.maximumLength
            && FunctionWords.contains(input.typed, language: input.sourceLanguage)

        let entry = WordChain.Entry(typed: input.typed, alternative: input.alternative,
                                    convertedIsFunctionWord: convertedIsFunction,
                                    typedIsFunctionWord: typedIsFunction,
                                    separator: " ", evidence: evidence, converted: false)

        let rescued = chain.retroactiveCandidates().count

        // Long enough to stand on its own.
        if input.typed.count >= input.minimumLength {
            return (decision == .convert ? .convert(carrying: rescued, reason: .ownEvidence)
                                         : (decision == .keep ? .keep : .wait),
                    evidence, entry)
        }

        // Too short alone. Is it eligible to be carried at all?
        let eligible = !WordChain.blocksSweep(entry)
            && (evidence.convertedIsKnownWord || convertedIsFunction)
        guard eligible, decision != .keep else { return (.keep, evidence, entry) }

        // The word before it just went, so this one goes with it.
        if chain.previousWasConverted {
            return (.convert(carrying: rescued, reason: .neighbour), evidence, entry)
        }

        // Or enough short words have piled up behind it that together they are
        // worth acting on. A sentence of nothing but grammar words — «о нём»,
        // «и то» — contains nothing long enough to trigger on its own, and
        // without this it is the one part of the text left in the wrong alphabet.
        let pending = chain.pendingRun()
        if !pending.isEmpty {
            let total = WordChain.combinedLength(pending) + 1 + input.typed.count
            if total >= input.minimumLength {
                return (.convert(carrying: pending.count, reason: .run), evidence, entry)
            }
        }
        return (.wait, evidence, entry)
    }
}
