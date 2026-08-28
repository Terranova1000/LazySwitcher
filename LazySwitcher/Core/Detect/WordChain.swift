import Foundation

/// The run of words typed since the last interruption, and the reasoning about
/// whether a short one can be settled by its neighbours.
///
/// This is what makes `xnj lktkfnm` become `что делать`. On its own `xnj` is
/// three characters, and three-character words carry a 2.78% false-positive rate
/// (03-ALGORITHM.md §14) — far too high to act on. But once the *next* word
/// converts, the short one is no longer a coin flip: it is part of a run that is
/// demonstrably in the wrong layout.
///
/// Two directions, and they cost different amounts:
///
/// · **Forward** — the previous word converted, so this short one may follow.
///   Free: we are about to type this word anyway.
/// · **Backward** — this word converted, so the short ones before it were wrong
///   too. Costs a larger replacement, because the text is already on screen and
///   has to be deleted and retyped as one run.
struct WordChain {

    struct Entry {
        let typed: String
        let alternative: String
        /// True when the converted reading is a grammar word of the target
        /// language — `то`, `нем`, `the`. Computed once, at commit time.
        let convertedIsFunctionWord: Bool
        /// The same for the reading that is on screen now.
        let typedIsFunctionWord: Bool
        /// What separated this word from the next, as it appears on screen.
        /// Only a plain space can be retyped, so anything else ends the chain.
        let separator: String
        let evidence: Scorer.Evidence
        let converted: Bool

        var onScreen: String { converted ? alternative : typed }
    }

    private(set) var entries: [Entry] = []

    /// How far back a retroactive fix may reach. Beyond three words the user has
    /// moved on, a sudden rewrite of half a line is alarming rather than helpful,
    /// and the odds of the run being homogeneous drop.
    static let maximumLookback = 3

    mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > 8 { entries.removeFirst() }
    }

    mutating func clear() { entries.removeAll() }

    /// Marks the tail as converted after a replacement went through.
    mutating func markConverted(count: Int) {
        for index in stride(from: entries.count - 1, to: max(entries.count - count - 1, -1), by: -1)
        where index >= 0 {
            let old = entries[index]
            entries[index] = Entry(typed: old.typed, alternative: old.alternative,
                                   convertedIsFunctionWord: old.convertedIsFunctionWord,
                                   typedIsFunctionWord: old.typedIsFunctionWord,
                                   separator: old.separator, evidence: old.evidence,
                                   converted: true)
        }
    }

    /// Was the word immediately before this one converted?
    var previousWasConverted: Bool { entries.last?.converted ?? false }

    /// Words immediately before the current one that should be swept along.
    ///
    /// Returned oldest-first, so the caller can rebuild the run in reading order.
    func retroactiveCandidates() -> [Entry] {
        var picked: [Entry] = []
        for entry in entries.reversed() {
            guard picked.count < Self.maximumLookback else { break }
            guard Self.isCandidate(entry) else { break }
            picked.append(entry)
        }
        return picked.reversed()
    }

    /// Deliberately strict. A retroactive change rewrites text the user has
    /// already read and moved past, so the bar is higher than for the word being
    /// typed, not lower.
    static func isCandidate(_ entry: Entry) -> Bool {
        // Already right, or already changed.
        guard !entry.converted else { return false }
        // Only a plain space can be put back; a Tab or Return has usually done
        // something we cannot undo, like sending the message.
        guard entry.separator == " " else { return false }
        // A real word of the language being typed is left alone. This is what
        // protects "a", "и", "no", "он" from being swept up by a neighbour's
        // confidence — except for one-letter words, where it protects nothing.
        //
        // The dictionaries list **every letter of the alphabet as a word**:
        // `j`, `b`, `v` are all in the English one, `о`, `и`, `в` in the Russian.
        // So "the typed reading is a real word" is true for every single letter
        // and carries no information at all — while blocking exactly the Russian
        // one-letter prepositions somebody typing on a Latin layout most wants
        // fixed. For those, membership of the curated grammar list is the honest
        // test: `a` and `i` are English words in the sense that matters and stay
        // put; `j` and `v` are not and may be carried.
        guard !blocksSweep(entry) else { return false }
        // The other reading has to be a real word or a grammar word. The model's
        // opinion used to be enough here, and that was too loose: `pwa` converts
        // to `зцф`, which is not a word in any sense, yet the model rated it more
        // Russian-looking than `pwa` is English-looking — so an abbreviation next
        // to a Russian word got dragged along with it. Being a word is a fact;
        // looking like one is not.
        return entry.evidence.convertedIsKnownWord || entry.convertedIsFunctionWord
    }

    /// Does the reading already on screen forbid touching this word?
    static func blocksSweep(_ entry: Entry) -> Bool {
        entry.typed.count == 1 ? entry.typedIsFunctionWord : entry.evidence.typedIsKnownWord
    }

    /// Can a short word ride on the previous one's conversion?
    ///
    /// Same bar as above, minus the separator condition — nothing has been typed
    /// past this word yet, so there is nothing to rebuild.
    static func mayInherit(_ evidence: Scorer.Evidence,
                           isFunctionWord: Bool,
                           typedIsFunctionWord: Bool = false,
                           typedLength: Int = 0) -> Bool {
        let blocked = typedLength == 1 ? typedIsFunctionWord : evidence.typedIsKnownWord
        guard !blocked else { return false }
        return evidence.convertedIsKnownWord || isFunctionWord
    }

    /// The trailing run of pending words that could be converted together.
    ///
    /// This is what makes a sentence of nothing but short words work. `j ytv`
    /// («о нём») is two words of one and three letters; neither is long enough
    /// to act on alone and neither has a long neighbour to be rescued by, so
    /// without this the pair simply stays in Latin while the rest of the
    /// sentence gets fixed.
    ///
    /// Taken together they are four characters of evidence, every one of them a
    /// grammar word of the other language and none of them a word of this one.
    /// That is a stronger case than any of them makes separately, and it is the
    /// two-word window from 03-ALGORITHM.md §7 doing the work it was designed
    /// for.
    func pendingRun() -> [Entry] {
        var run: [Entry] = []
        for entry in entries.reversed() {
            guard Self.isCandidate(entry) else { break }
            run.append(entry)
            if run.count >= Self.maximumLookback { break }
        }
        return run.reversed()
    }

    /// Combined length of a run, including the spaces between its words.
    static func combinedLength(_ run: [Entry]) -> Int {
        guard !run.isEmpty else { return 0 }
        return run.reduce(0) { $0 + $1.typed.count } + run.count - 1
    }
}
