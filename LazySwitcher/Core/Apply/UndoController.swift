import Foundation

/// Puts back exactly what was there, for five seconds after a replacement.
///
/// Byte for byte is the requirement, not "close enough": an undo that restores
/// a slightly different string is worse than no undo, because the user stops
/// being able to trust either direction.
///
/// We keep our own rather than leaning on ⌘Z because backspaces plus typing land
/// as one undo entry in some editors and N+1 in others, and there is no portable
/// way to make it atomic.
final class UndoController {

    struct Pending {
        let original: String
        let replacement: String
        let bundleID: String
        let at: Date
    }

    private(set) var pending: Pending?
    var window: TimeInterval = 5.0

    /// Provided by the caller so tests need not sleep.
    var now: () -> Date = Date.init

    func arm(original: String, replacement: String, bundleID: String) {
        pending = Pending(original: original, replacement: replacement,
                          bundleID: bundleID, at: now())
    }

    var isAvailable: Bool {
        guard let pending else { return false }
        return now().timeIntervalSince(pending.at) <= window
    }

    /// Returns what to undo, and forgets it. Nil if nothing is pending or the
    /// window has closed.
    func consume() -> Pending? {
        guard isAvailable, let pending else {
            self.pending = nil
            return nil
        }
        self.pending = nil
        return pending
    }

    /// Anything that moves the caret invalidates the undo: our replacement
    /// characters are no longer the ones sitting before the cursor.
    func invalidate() { pending = nil }
}
