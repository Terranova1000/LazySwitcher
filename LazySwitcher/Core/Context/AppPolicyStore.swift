import Foundation

/// Which apps we are allowed to touch, and how much.
///
/// The built-in exclusions are not a starting suggestion the user can clear with
/// one click. Getting it wrong in a terminal or a password manager is the
/// failure this whole project is organised around, so those entries are locked
/// and changing one takes an explicit confirmation with a warning.
final class AppPolicyStore {

    /// Apps where we never act, whatever the user has configured.
    ///
    /// Terminals and remote desktops: a mangled command is the worst outcome we
    /// can produce, and a *partially* mangled one that still runs is worse.
    /// Password managers: self-evident. VMs and remote desktops: keystrokes are
    /// forwarded somewhere we cannot see, so we have no idea what field they
    /// land in. Games: they read the keyboard directly and our latency shows.
    static let lockedExclusions: Set<String> = [
        // Терминалы
        "com.apple.Terminal", "com.googlecode.iterm2", "co.zeit.hyper",
        "io.alacritty", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "com.github.wez.wezterm",
        // Менеджеры паролей и ключи
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
        "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass", "com.apple.keychainaccess",
        "com.maxgoedjen.Secretive.Host",
        // Виртуализация и удалённый рабочий стол
        "com.parallels.desktop.console", "com.vmware.fusion",
        "org.virtualbox.app.VirtualBox", "com.utmapp.UTM",
        "com.microsoft.rdc.macos", "com.teamviewer.TeamViewer",
        "com.apple.ScreenSharing", "com.realvnc.vncviewer",
        // Системные окна ввода
        "com.apple.loginwindow", "com.apple.SecurityAgent",
    ]

    /// Editors and IDEs. Off by default because our idea of a word is wrong in
    /// code, but the user may switch them on — unlike the locked set above.
    static let defaultDisabled: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.apple.dt.Xcode", "com.jetbrains.intellij", "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm", "com.jetbrains.CLion", "com.jetbrains.goland",
        "com.sublimetext.4", "com.github.atom", "dev.zed.Zed",
        "com.panic.Nova", "com.barebones.bbedit", "org.vim.MacVim",
    ]

    /// Browsers that never expose the role of the focused field.
    ///
    /// Measured, not assumed (00-DECISIONS.md, Н10 and Н12): Chromium and Gecko
    /// keep their web accessibility tree unbuilt, and neither turns on Secure
    /// Input for `<input type="password">`. So inside these apps we have no
    /// signal whatsoever that the caret is in a password field.
    ///
    /// Rather than refuse outright — which would make the product useless for
    /// anyone whose main browser is Chrome — they run in hotkey-only mode. We
    /// never touch anything on our own there; the user pressing the hotkey is
    /// the signal we cannot get any other way, and nobody asks to convert their
    /// password. Waking Chromium with the private `AXEnhancedUserInterface` was
    /// considered and rejected: it makes windows jump around.
    static let opaqueBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.mozilla.librewolf", "app.zen-browser.zen",
    ]

    private var userOverrides: [String: AppPolicy] = [:]

    init(loadingFrom settings: Settings? = nil) {
        guard let settings else { return }
        for (bundleID, raw) in settings.storedPolicies() {
            guard let policy = AppPolicy(rawValue: UInt8(raw)), !Self.lockedExclusions.contains(bundleID)
            else { continue }
            userOverrides[bundleID] = policy
        }
    }

    func policy(for bundleID: String) -> AppPolicy {
        // Locked first: no override reaches past this.
        if Self.lockedExclusions.contains(bundleID) { return .disabled }
        if let override = userOverrides[bundleID] { return override }
        if Self.defaultDisabled.contains(bundleID) { return .disabled }
        if Self.opaqueBrowsers.contains(bundleID) { return .hotkeyOnly }
        // An unknown app starts cautious and earns its way up (03-ALGORITHM §10).
        return .automatic
    }

    func isLocked(_ bundleID: String) -> Bool {
        Self.lockedExclusions.contains(bundleID)
    }

    func hidesFieldRoles(_ bundleID: String) -> Bool {
        Self.opaqueBrowsers.contains(bundleID)
    }

    /// Returns false — and changes nothing — for a locked app.
    @discardableResult
    func setPolicy(_ policy: AppPolicy, for bundleID: String) -> Bool {
        guard !isLocked(bundleID) else { return false }
        userOverrides[bundleID] = policy
        return true
    }

    func clearOverride(for bundleID: String) {
        userOverrides.removeValue(forKey: bundleID)
    }
}
