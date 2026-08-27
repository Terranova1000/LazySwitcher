import Foundation

/// Remembers which corrections the user rejected.
///
/// An undo is the most valuable signal in the whole system and it costs nothing
/// to collect: it is a labelled negative example, produced by the user at the
/// exact moment they cared. Nothing else we could measure comes close.
///
/// What it stores is narrow on purpose: **only words that took part in a
/// correction, and only those the user had an opinion about.** Not a history of
/// typing. A file listing everything somebody wrote would be the same mistake
/// Punto made with its "diary", and that single feature is why people did not
/// trust it.
final class FeedbackStore {

    /// Undo it once and it stops being corrected for this session; three times
    /// and it stops for good. Three rather than one because a single undo can be
    /// a slip, and because a permanent rule the user did not intend is harder to
    /// discover than a temporary one.
    static let permanentAfter = 3

    private var sessionRejections: [String: Int] = [:]
    private var permanent: Set<String>
    private let defaults = UserDefaults.standard
    private let storageKey = "rejectedWords"

    init() {
        permanent = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    /// Should this word be left alone?
    func isRejected(_ word: String) -> Bool {
        let key = word.lowercased()
        return permanent.contains(key) || (sessionRejections[key] ?? 0) > 0
    }

    /// The user undid a correction of this word.
    @discardableResult
    func recordUndo(of word: String) -> Bool {
        let key = word.lowercased()
        let count = (sessionRejections[key] ?? 0) + 1
        sessionRejections[key] = count
        guard count >= Self.permanentAfter, !permanent.contains(key) else { return false }
        permanent.insert(key)
        persist()
        return true          // стало постоянным
    }

    /// Everything the app has learned, for the settings screen. Learning the user
    /// cannot see and undo is a black box that will one day learn something silly
    /// with no way to fix it.
    var permanentExclusions: [String] { permanent.sorted() }

    func forget(_ word: String) {
        permanent.remove(word.lowercased())
        sessionRejections.removeValue(forKey: word.lowercased())
        persist()
    }

    func forgetEverything() {
        permanent.removeAll()
        sessionRejections.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(Array(permanent).sorted(), forKey: storageKey)
    }
}
