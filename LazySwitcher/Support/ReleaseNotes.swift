import Foundation

/// What changed in the version now running, read from inside the bundle.
///
/// Deliberately not fetched. The updater is the one place allowed to touch the
/// network (rule 3), and it exists to *find* a new version; describing the
/// version already installed needs no connection at all, and reading it from
/// the bundle means the notes are right even with update checking switched off,
/// offline, or if the repository ever moves.
///
/// The text lives in `WhatsNew.txt`, localised the ordinary way, so the person
/// reads it in the language the rest of the interface is in.
enum ReleaseNotes {

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// The notes shipped with this build, or nil if none were included.
    static func text() -> String? {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether to show the notes unprompted, and record that we did.
    ///
    /// Three rules, in order:
    ///
    /// · Never on a first run. Somebody meeting the application for the first
    ///   time is served by the welcome screen, not by a list of what changed in
    ///   a version they have never used.
    /// · Only when the version actually changed.
    /// · Once per version. Reopening the application does not bring it back;
    ///   the menu item is there for anyone who wants it again.
    static func shouldPresentAutomatically(settings: Settings = .shared) -> Bool {
        defer { settings.lastSeenVersion = currentVersion }
        return shouldPresent(seenVersion: settings.lastSeenVersion,
                             current: currentVersion,
                             hasNotes: text() != nil)
    }

    /// The rule on its own, over plain values.
    static func shouldPresent(seenVersion: String?, current: String, hasNotes: Bool) -> Bool {
        guard hasNotes else { return false }
        guard let seenVersion else { return false }   // first run: the welcome screen's job
        return seenVersion != current
    }
}
