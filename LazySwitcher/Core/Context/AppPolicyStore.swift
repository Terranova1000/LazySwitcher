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

    private var userOverrides: [String: AppPolicy] = [:]

    func policy(for bundleID: String) -> AppPolicy {
        // Locked first: no override reaches past this.
        if Self.lockedExclusions.contains(bundleID) { return .disabled }
        if let override = userOverrides[bundleID] { return override }
        if Self.defaultDisabled.contains(bundleID) { return .disabled }
        // An unknown app starts cautious and earns its way up (03-ALGORITHM §10).
        return .automatic
    }

    func isLocked(_ bundleID: String) -> Bool {
        Self.lockedExclusions.contains(bundleID)
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
