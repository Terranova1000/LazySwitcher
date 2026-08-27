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
