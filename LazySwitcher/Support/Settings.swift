import AppKit

/// Everything the user can change, and the only place that touches UserDefaults.
///
/// Nothing here records anything about what was typed — the store holds
/// preferences and app policies, never text (CLAUDE.md rule 1).
final class Settings {

    static let shared = Settings()
    private let defaults = UserDefaults.standard

    enum Key: String {
        case automaticEnabled = "automaticEnabled"
        case minimumLength = "minimumLength"
        case switchLayoutAfterReplacement = "switchLayoutAfterReplacement"
        case soundEnabled = "soundEnabled"
        case soundName = "soundName"
        case soundVolume = "soundVolume"
        case actInUnidentifiedFields = "actInUnidentifiedFields"
        case appPolicies = "appPolicies"
        case hotkeyStyle = "hotkeyStyle"
        case checkUpdatesAutomatically = "checkUpdatesAutomatically"
        case lastUpdateCheck = "lastUpdateCheck"
        case bannerHidden = "bannerHidden"
        case hasSeenWelcome = "hasSeenWelcome"
    }

    private init() {
        defaults.register(defaults: [
            Key.automaticEnabled.rawValue: true,
            Key.minimumLength.rawValue: 5,
            Key.switchLayoutAfterReplacement.rawValue: true,
            Key.soundEnabled.rawValue: true,
            Key.soundName.rawValue: "Tink",
            Key.soundVolume.rawValue: 0.5,
            Key.actInUnidentifiedFields.rawValue: false,
            Key.hotkeyStyle.rawValue: HotkeyStyle.doubleShift.rawValue,
            Key.checkUpdatesAutomatically.rawValue: false,
        ])
    }

    var automaticEnabled: Bool {
        get { defaults.bool(forKey: Key.automaticEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.automaticEnabled.rawValue) }
    }

    /// Five by default because that is where measured false positives reach zero;
    /// four is offered because 0.87% is a trade some people will want to make.
    /// Below four is not offered at all.
    var minimumLength: Int {
        get { max(4, min(8, defaults.integer(forKey: Key.minimumLength.rawValue))) }
        set { defaults.set(max(4, min(8, newValue)), forKey: Key.minimumLength.rawValue) }
    }

    var switchLayoutAfterReplacement: Bool {
        get { defaults.bool(forKey: Key.switchLayoutAfterReplacement.rawValue) }
        set { defaults.set(newValue, forKey: Key.switchLayoutAfterReplacement.rawValue) }
    }

    var hotkeyStyle: HotkeyStyle {
        get { HotkeyStyle(rawValue: defaults.string(forKey: Key.hotkeyStyle.rawValue) ?? "")
                ?? .doubleShift }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyStyle.rawValue) }
    }

    // MARK: - Updates

    /// Off by default, and it stays off unless the user turns it on.
    ///
    /// This is the one place where the app is allowed to open a network
    /// connection, and the promise it bends is the project's main one, so the
    /// defaults are the strict reading: nothing happens unless asked.
    var checkUpdatesAutomatically: Bool {
        get { defaults.bool(forKey: Key.checkUpdatesAutomatically.rawValue) }
        set { defaults.set(newValue, forKey: Key.checkUpdatesAutomatically.rawValue) }
    }

    /// Whether the About screen shows the banner. Purely cosmetic, remembered so
    /// somebody who finds it too large is not shown it again every time.
    var bannerHidden: Bool {
        get { defaults.bool(forKey: Key.bannerHidden.rawValue) }
        set { defaults.set(newValue, forKey: Key.bannerHidden.rawValue) }
    }

    /// First run has happened. Guards the welcome screen, not the permission
    /// flow — those are different questions and were once the same flag.
    var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: Key.hasSeenWelcome.rawValue) }
        set { defaults.set(newValue, forKey: Key.hasSeenWelcome.rawValue) }
    }

    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck.rawValue) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck.rawValue) }
    }

    // MARK: - Sound

    /// Built-in system sounds that are short and neutral enough not to grate on
    /// the fiftieth correction of the day.
    static let availableSounds = ["Tink", "Pop", "Morse", "Bottle", "Frog", "Purr", "Submarine"]

    var soundEnabled: Bool {
        get { defaults.bool(forKey: Key.soundEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.soundEnabled.rawValue) }
    }

    var soundName: String {
        get { defaults.string(forKey: Key.soundName.rawValue) ?? "Tink" }
        set { defaults.set(newValue, forKey: Key.soundName.rawValue) }
    }

    var soundVolume: Float {
        get { defaults.float(forKey: Key.soundVolume.rawValue) }
        set { defaults.set(newValue, forKey: Key.soundVolume.rawValue) }
    }

    func playFeedbackSound() {
        guard soundEnabled, let sound = NSSound(named: soundName) else { return }
        sound.volume = soundVolume
        sound.play()
    }

    // MARK: - Where we are allowed to work

    /// Act in apps whose field type we cannot determine — Chrome, Firefox, some
    /// Electron apps.
    ///
    /// Off by default, and the wording in the UI has to be blunt about why: in
    /// those apps there is no signal at all that the caret is in a password
    /// field, neither the accessibility subrole nor Secure Input
    /// (00-DECISIONS.md, Н10 and Н12). Turning this on means automatic
    /// replacement can fire inside a password field. It exists because "does not
    /// work in my browser" is a real problem too, and because the choice is the
    /// user's to make once they know what it costs.
    var actInUnidentifiedFields: Bool {
        get { defaults.bool(forKey: Key.actInUnidentifiedFields.rawValue) }
        set { defaults.set(newValue, forKey: Key.actInUnidentifiedFields.rawValue) }
    }

    // MARK: - Per-app policies

    func storedPolicies() -> [String: Int] {
        defaults.dictionary(forKey: Key.appPolicies.rawValue) as? [String: Int] ?? [:]
    }

    func store(policy: AppPolicy, for bundleID: String) {
        var all = storedPolicies()
        all[bundleID] = Int(policy.rawValue)
        defaults.set(all, forKey: Key.appPolicies.rawValue)
    }

    func removePolicy(for bundleID: String) {
        var all = storedPolicies()
        all.removeValue(forKey: bundleID)
        defaults.set(all, forKey: Key.appPolicies.rawValue)
    }
}
