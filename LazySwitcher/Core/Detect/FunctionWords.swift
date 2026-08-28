import Foundation

/// Short words that carry grammar rather than meaning: prepositions,
/// conjunctions, particles, pronouns, articles.
///
/// They exist as a separate list because the general rules cannot reach them.
/// Automatic replacement starts at five characters, since below that the
/// measured false-positive rate climbs (03-ALGORITHM.md §14) — but a Russian
/// sentence typed on a Latin layout is full of `в`, `и`, `о`, `не`, `то`,
/// `нем`, and leaving those in Latin while the long words get fixed produces
/// something worse than either: half-converted text.
///
/// A curated list is safe where a threshold is not, for a specific reason: these
/// words are checked against a set somebody wrote down deliberately, not against
/// a probability. `зцф` is not on it, so `pwa` stays an abbreviation.
///
/// The lists are deliberately conservative. A word earns its place by being both
/// **frequent** and **unambiguous** — `то` is here, `рот` is not, because `hjn`
/// could plausibly be somebody's initials.
enum FunctionWords {

    static func contains(_ word: String, language: String) -> Bool {
        switch language {
        case "ru": return russian.contains(word.lowercased())
        case "en": return english.contains(word.lowercased())
        default:   return false
        }
    }

    /// Longest entry, so callers can skip the lookup for anything longer.
    ///
    /// Computed rather than written down. A constant here drifts the moment
    /// somebody adds a word — and it drifts silently, because a lookup skipped
    /// on a length check simply returns false and the word quietly stops being
    /// carried.
    static let maximumLength: Int =
        (russian.union(english)).map(\.count).max() ?? 0

    static let russian: Set<String> = [
        // предлоги
        "в", "во", "к", "ко", "с", "со", "о", "об", "обо", "на", "за", "по", "до",
        "из", "изо", "у", "от", "ото", "для", "при", "над", "надо", "под", "подо",
        "про", "без", "безо", "через", "между", "перед", "около", "после", "кроме",
        "вместо", "среди", "вокруг", "внутри", "против", "сквозь", "ради",
        // союзы и частицы
        "и", "а", "но", "да", "же", "ли", "бы", "не", "ни", "то", "так", "как",
        "чем", "чтобы", "если", "когда", "пока", "хотя", "или", "либо", "тоже",
        "также", "ведь", "разве", "уже", "ещё", "еще", "лишь", "даже", "почти",
        "вот", "там", "тут", "здесь", "туда", "сюда", "где", "куда", "зачем",
        "потом", "затем", "очень", "просто", "конечно", "нужно", "надо", "можно",
        // местоимения
        "я", "ты", "он", "она", "оно", "мы", "вы", "они", "мне", "меня", "мной",
        "тебе", "тебя", "тобой", "ему", "его", "им", "ей", "её", "ее", "их",
        "нам", "нас", "нами", "вам", "вас", "вами", "них", "ним", "ними",
        "нем", "нём", "неё", "нее", "него", "тот", "та", "те", "том", "той",
        "тем", "этот", "эта", "это", "эти", "этом", "этой", "этих", "этим",
        "весь", "вся", "всё", "все", "всех", "всем", "себя", "себе", "свой",
        "своё", "свои", "мой", "моя", "моё", "твой", "наш", "ваш", "кто", "что",
        // связки
        "быть", "был", "была", "было", "были", "есть", "нет", "да",
    ]

    static let english: Set<String> = [
        // артикли и предлоги
        "a", "an", "the", "of", "to", "in", "on", "at", "by", "for", "with",
        "from", "into", "onto", "over", "under", "up", "down", "out", "off",
        "about", "after", "before", "between", "through", "during", "without",
        "within", "across", "against", "among", "around", "behind", "below",
        // союзы и частицы
        "and", "or", "but", "if", "so", "as", "than", "then", "that", "though",
        "while", "when", "where", "why", "how", "because", "since", "until",
        "not", "no", "yes", "too", "very", "just", "only", "also", "even",
        "still", "well", "back", "here", "there", "now", "again", "once",
        // местоимения
        "i", "me", "my", "mine", "we", "us", "our", "ours", "you", "your",
        "yours", "he", "him", "his", "she", "her", "hers", "it", "its", "they",
        "them", "their", "this", "these", "those", "who", "whom", "whose",
        "what", "which", "some", "any", "each", "all", "both", "few", "more",
        "most", "other", "such", "own", "same",
        // связки
        "is", "am", "are", "was", "were", "be", "been", "being", "do", "does",
        "did", "have", "has", "had", "can", "could", "will", "would", "shall",
        "should", "may", "might", "must",
    ]
}
