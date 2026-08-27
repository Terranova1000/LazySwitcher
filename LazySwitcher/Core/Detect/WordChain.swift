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
        // A real word of the language being typed is left alone, full stop.
        // This is what protects "a", "и", "no", "он" from being swept up by a
        // neighbour's confidence.
        guard !entry.evidence.typedIsKnownWord else { return false }
        // And the other reading has to be a real word, or the model has to be
        // positively in favour. "Not a word either way" stays untouched: it is
        // probably a name, an abbreviation or a typo.
        return entry.evidence.convertedIsKnownWord || entry.evidence.perCharacter > 0
    }

    /// Can a short word ride on the previous one's conversion?
    ///
    /// Same bar as above, minus the separator condition — nothing has been typed
    /// past this word yet, so there is nothing to rebuild.
    static func mayInherit(_ evidence: Scorer.Evidence) -> Bool {
        guard !evidence.typedIsKnownWord else { return false }
        return evidence.convertedIsKnownWord || evidence.perCharacter > 0
    }
}
