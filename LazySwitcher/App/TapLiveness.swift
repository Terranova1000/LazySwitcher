import Foundation

/// Decides, once a second, whether the tap thread has to be replaced.
///
/// A replacement has to be earned now, because it was never free. Every restart
/// ran the old and the new tap thread side by side for a moment, and one such
/// moment is how a process ended up with two taps feeding one word buffer —
/// every letter recorded twice, `сообщение` scored as `ссооооббщщееннииее` and
/// "corrected" into Latin nonsense.
///
/// And almost none of those restarts were needed. The tap thread proves it is
/// alive by advancing a counter every five seconds, and silence was measured on
/// the wall clock. A machine that slept for a quarter of an hour woke up to a
/// quarter of an hour of silence, and whichever timer happened to fire first
/// after waking decided whether a perfectly healthy tap got torn down.
///
/// Two changes, either of which alone would have prevented that:
///   · silence is counted in awake time, which stands still during sleep;
///   · silence alone is never enough. The thread is asked directly first, and
///     only a thread that does not answer is replaced. A thread that is merely
///     late answers within milliseconds of being asked.
struct TapLiveness {

    enum Action: Equatable {
        case none
        /// Ask the tap thread to check in now.
        case probe
        /// It was asked and did not answer.
        case restart
    }

    /// Awake seconds without a tick before the thread is asked.
    static let silenceBeforeProbe: TimeInterval = 15
    /// How long an asked thread has to answer.
    static let answerTime: TimeInterval = 5
    /// Restarts never come closer together than this.
    static let restartSpacing: TimeInterval = 30

    private var lastTick: UInt64?
    private var lastTickAt: TimeInterval = 0
    private var probedAt: TimeInterval?
    private var lastRestartAt: TimeInterval = -.infinity

    /// - Parameters:
    ///   - tick: the tap thread's watchdog counter.
    ///   - now: awake time — `ProcessInfo.systemUptime`, not `Date()`.
    mutating func observe(tick: UInt64, now: TimeInterval) -> Action {
        if tick != lastTick {
            lastTick = tick
            lastTickAt = now
            probedAt = nil
            return .none
        }
        guard now - lastTickAt > Self.silenceBeforeProbe else { return .none }
        guard let probedAt else {
            self.probedAt = now
            return .probe
        }
        guard now - probedAt > Self.answerTime,
              now - lastRestartAt > Self.restartSpacing else { return .none }
        lastRestartAt = now
        lastTickAt = now
        self.probedAt = nil
        return .restart
    }
}
