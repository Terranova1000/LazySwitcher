import Foundation

/// What to do when Accessibility access appears while we are already running.
///
/// Pulled out of `AppDelegate` for one reason: one of these outcomes restarts
/// the process, and a rule about when a program may restart itself has to be
/// readable and testable on its own. Written as a decision over plain values,
/// with no clock and no side effects, so the loop-safety argument can be
/// checked by a test rather than by reasoning about timers.
enum PermissionRecovery {

    enum Action: Equatable {
        /// The tap opened. Nothing else to do.
        case granted
        /// Access arrived after we launched, so our own `CGPreflight*` cache is
        /// stale (Н6) and only a fresh process can see the grant.
        case relaunch
        /// Trusted, but the tap will not open and a restart cannot help:
        /// the "green checkbox, dead APIs" state that needs `tccutil reset`.
        case stuck
        /// Nobody has granted anything yet.
        case keepWaiting
        /// Long enough. Stop polling; onboarding and the menu still re-check.
        case giveUp
    }

    /// - Parameters:
    ///   - trusted: `AXIsProcessTrusted()` right now.
    ///   - trustedAtStart: the same value when we began watching. The difference
    ///     between the two is the whole question: only a transition from false
    ///     means a restart would achieve anything.
    ///   - tapStarted: whether the event tap opened on this attempt.
    ///   - alreadyRelaunched: whether this process has restarted itself before.
    ///   - secondsSinceLastRelaunch: across processes, from stored state.
    ///   - elapsed: seconds spent waiting.
    static func decide(trusted: Bool,
                       trustedAtStart: Bool,
                       tapStarted: Bool,
                       alreadyRelaunched: Bool,
                       secondsSinceLastRelaunch: Double,
                       elapsed: Double) -> Action {
        guard trusted else { return elapsed > 300 ? .giveUp : .keepWaiting }
        if tapStarted { return .granted }
        // Trusted before we started and still broken: restarting lands in the
        // same place, one second later, forever.
        if trustedAtStart { return .stuck }
        // Never twice. Any path that gets here a second time is a bug, and the
        // cost of that bug would be a machine launching copies of this app in a
        // loop, so it is refused on the value rather than on the argument.
        if alreadyRelaunched || secondsSinceLastRelaunch <= 60 { return .stuck }
        return .relaunch
    }
}
