import Foundation

/// A word begun in one layout and finished in another.
///
/// It happens because switching the layout is not instant. After a correction
/// we switch, so the rest of the phrase comes out right; measured on macOS 26,
/// the change lands 23–63 ms later when we watch for it and up to 277 ms later
/// when we wait to be told. Anything typed inside that window still comes out
/// in the old alphabet, so a word begun there is half one and half the other:
/// «как lела», «пщщпду».
///
/// The repair is deterministic, not statistical. The keys are known and the two
/// layouts are known, so there are exactly two readings of what the person
/// meant — the layout they ended up in and the other one — and the dictionary
/// says which of them is a word. Anything else is left alone: a mixed word
/// nobody can vouch for is not something to rewrite on a guess.
enum SeamRepair {

    struct Candidate: Equatable {
        /// The whole word read through one layout.
        let text: String
        /// The language of that layout, for the dictionary lookup.
        let language: String
    }

    /// - Parameters:
    ///   - onScreen: the word as it actually appears — each key through the
    ///     layout it was typed in.
    ///   - candidates: the readings worth considering, best first: the layout
    ///     in force, then the other one.
    ///   - isKnownWord: the dictionary, asked as `(word, language)`.
    /// - Returns: the reading to put on screen, or nil to leave the word alone.
    static func meant(onScreen: String, candidates: [Candidate],
                      isKnownWord: (String, String) -> Bool) -> Candidate? {
        candidates.first { candidate in
            guard !candidate.text.isEmpty else { return false }
            // Already what is on screen: there is nothing to repair, and
            // rewriting it would be a replacement that changes nothing.
            guard candidate.text != onScreen else { return false }
            return isKnownWord(candidate.text, candidate.language)
        }
    }
}
