import AppKit
import ApplicationServices
import CoreGraphics

/// Everything we are allowed to believe about our own privileges.
///
/// The ordering here is not cosmetic. `AXIsProcessTrusted()` keeps returning true
/// after the user revokes access, so it never decides anything; `CGPreflight*` is
/// the primary source of truth, and a throwaway tap is the cross-check we run once
/// at launch rather than on a timer (docs/04-PLATFORM.md §1.2).
enum Permissions {

    struct State: Equatable {
        var canListen: Bool     // CGPreflightListenEventAccess
        var canPost: Bool       // CGPreflightPostEventAccess
        var axTrusted: Bool     // advisory only — known to lie
        var probeTapCreated: Bool

        /// The only question that matters: can we actually do our job?
        var isUsable: Bool { canListen && canPost }

        /// Green checkbox in System Settings, dead APIs underneath. This is the
        /// signature of a designated-requirement mismatch, and no amount of
        /// clicking in the UI fixes it — only `tccutil reset` does.
        var looksStuck: Bool { axTrusted && !probeTapCreated }
    }

    static func current(runProbe: Bool = true) -> State {
        State(canListen: CGPreflightListenEventAccess(),
              canPost: CGPreflightPostEventAccess(),
              axTrusted: AXIsProcessTrusted(),
              probeTapCreated: runProbe ? probeTap() : false)
    }

    static func request() {
        _ = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()
    }

    /// Creates a tap and immediately destroys it. Tail-append so we never sit in
    /// front of anyone's events, and keyboard-only so a missing privilege fails
    /// loudly with nil instead of handing back a tap that never fires.
    static func probeTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .tailAppendEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: { _, _, event, _ in
                                               Unmanaged.passUnretained(event)
                                           },
                                           userInfo: nil)
        else { return false }
        CFMachPortInvalidate(port)
        return true
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
