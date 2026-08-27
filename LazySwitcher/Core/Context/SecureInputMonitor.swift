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

    /// Who turned Secure Input on — **does not work, and is kept as evidence.**
    ///
    /// The documented route is IORegistry: `IOService:/IOResources/IOConsoleUsers`
    /// → `CGSSessionSecureInputPID`. On macOS 15.7.7 that key is simply absent,
    /// verified while the mode was definitely on and `IsSecureEventInputEnabled()`
    /// agreed it was (00-DECISIONS.md, Н13). So this returns nil in practice.
    ///
    /// Kept rather than deleted because the alternative is someone re-deriving
    /// the same dead end from the same documentation in six months. Callers must
    /// already handle nil, and the menu says "ввод защищён системой" with no
    /// name — which is the better message anyway: the older reports of this API
    /// naming the wrong background process mean a name here could be a lie.
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
