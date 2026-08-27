import AppKit
import Carbon.HIToolbox
import IOKit

/// Watches the system-wide Secure Input flag.
///
/// When any process turns Secure Input on, keyboard events stop reaching every
/// tap in the system — ours included. That is not a policy we implement, it is a
/// guarantee the OS makes, and it is the reason we can honestly say we cannot
/// read passwords. What we add on top is the bookkeeping: stop reacting to
/// anything, wipe what we hold, and say so in the UI.
///
/// The flag is global and can stick for hours (Terminal's "Secure Keyboard Entry",
/// password managers, Chrome forgetting to turn it off). That is normal, not an
/// edge case.
final class SecureInputMonitor {

    private(set) var isEnabled: Bool = false
    private var timer: Timer?

    /// Called on the main thread whenever the flag flips.
    var onChange: ((Bool) -> Void)?

    func start() {
        refresh()
        // 1 s poll: there is no notification for this, and the flag is cheap to read.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        let now = IsSecureEventInputEnabled()
        guard now != isEnabled else { return }
        isEnabled = now
        onChange?(now)
    }

    /// Best guess at who turned it on, for the menu text.
    ///
    /// macOS has a long-standing bug where a background app is misreported, so
    /// every caller must phrase this as a guess rather than a fact.
    static func likelyResponsibleProcess() -> (pid: pid_t, name: String)? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        guard let consoleUsers = IORegistryEntrySearchCFProperty(
            root, kIOServicePlane, "IOConsoleUsers" as CFString,
            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
        ) as? [[String: Any]] else { return nil }

        for session in consoleUsers {
            if let pid = session["kCGSSessionSecureInputPID"] as? pid_t, pid > 0 {
                let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                    ?? "процесс \(pid)"
                return (pid, name)
            }
        }
        return nil
    }
}
