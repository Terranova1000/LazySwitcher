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
        /// Input generation at the moment the replacement was made.
        ///
        /// Without it the undo survives typing. After an automatic replacement
        /// the word buffer is empty and the next letter merely extends it — no
        /// reset fires, nothing invalidates anything — so the undo stayed armed
        /// while the user carried on writing. Pressing the hotkey then deleted
        /// as many characters as the replacement had been, from wherever the
        /// caret now was: their own new text.
        let generation: UInt64
    }

    private(set) var pending: Pending?
    var window: TimeInterval = 5.0

    /// Provided by the caller so tests need not sleep.
    var now: () -> Date = Date.init

    func arm(original: String, replacement: String, bundleID: String, generation: UInt64) {
        pending = Pending(original: original, replacement: replacement,
                          bundleID: bundleID, at: now(), generation: generation)
    }

    var isAvailable: Bool {
        guard let pending else { return false }
        return now().timeIntervalSince(pending.at) <= window
    }

    /// Returns what to undo, and forgets it.
    ///
    /// Nil if nothing is pending, the window has closed, or anything has been
    /// typed since — the last of those being the one that used to eat text.
    func consume(currentGeneration: UInt64) -> Pending? {
        guard isAvailable, let pending, pending.generation == currentGeneration else {
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
