import Foundation

/// Asking, once, whether somebody wants to support the work.
///
/// **Switched off.** `destination` is nil, and while it is nil nothing is ever
/// shown — `shouldAsk` returns false before it looks at anything else. To turn
/// this on, put the address people should be sent to in `destination`. That is
/// the whole switch; everything below is already written and tested.
///
/// The rules it will follow when enabled, which are the point of doing this in
/// code rather than by feel:
///
/// · Not in the first week. Somebody still deciding whether the application is
///   any good has not yet been given a reason to pay for it, and asking early
///   reads as the point of the exercise rather than an afterthought.
/// · Once, then not for three months.
/// · "Do not ask again" is permanent and is offered on the first showing, not
///   hidden behind a second one.
/// · No network, no counting, nothing recorded anywhere but this machine —
///   the promise the application makes about keystrokes applies to this too.
enum SupportPrompt {

    /// Where "support the work" leads. Nil disables the whole feature.
    ///
    /// Nil on purpose: there is nowhere to send anyone yet, and a button that
    /// opens a page which does not exist is worse than no button.
    static let destination: URL? = nil

    static let quietPeriodBeforeFirstAsk: TimeInterval = 7 * 24 * 3600
    static let quietPeriodBetweenAsks: TimeInterval = 90 * 24 * 3600

    static var isEnabled: Bool { destination != nil }

    /// Records the first run if it has not been recorded yet.
    ///
    /// Called at every launch; writes once. Without it an installation that
    /// predates this feature would have no start date, and "a week of use" would
    /// be measured from whenever the person happened to update.
    static func noteLaunch(now: Date = Date(), settings: Settings = .shared) {
        if settings.firstRunDate == nil { settings.firstRunDate = now }
    }

    static func shouldAsk(now: Date = Date(), settings: Settings = .shared) -> Bool {
        shouldAsk(enabled: isEnabled,
                  silenced: settings.supportSilenced,
                  firstRun: settings.firstRunDate,
                  lastAsked: settings.supportAskedAt,
                  now: now)
    }

    /// The rule on its own, over plain values.
    static func shouldAsk(enabled: Bool, silenced: Bool,
                          firstRun: Date?, lastAsked: Date?, now: Date) -> Bool {
        guard enabled, !silenced else { return false }
        guard let firstRun, now.timeIntervalSince(firstRun) >= quietPeriodBeforeFirstAsk else {
            return false
        }
        guard let lastAsked else { return true }
        return now.timeIntervalSince(lastAsked) >= quietPeriodBetweenAsks
    }

    static func noteAsked(now: Date = Date(), settings: Settings = .shared) {
        settings.supportAskedAt = now
    }

    static func silence(settings: Settings = .shared) {
        settings.supportSilenced = true
    }
}
