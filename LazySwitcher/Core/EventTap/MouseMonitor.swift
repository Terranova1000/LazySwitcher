import AppKit

/// Watches for mouse clicks, which invalidate the word buffer.
///
/// A click can put the caret anywhere. If we keep the buffer across one, our
/// synthetic backspaces will delete characters somewhere else entirely — the
/// worst class of bug this project can produce, because it silently damages text
/// the user has already written.
///
/// Separate from the event tap on purpose: the tap's mask is deliberately
/// keyboard-only so that a missing privilege fails loudly with a nil tap instead
/// of quietly handing back a tap that never fires. Mouse events go through
/// `NSEvent`'s global monitor instead, which needs no separate grant for mouse
/// and only ever observes.
final class MouseMonitor {

    private var monitor: Any?
    var onClick: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.onClick?()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}
