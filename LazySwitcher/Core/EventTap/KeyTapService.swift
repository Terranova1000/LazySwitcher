import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Owns the one and only `CGEvent.tapCreate` in the project.
///
/// Runs the tap on a dedicated thread with its own run loop so that nothing the
/// UI does can ever delay an event. The callback does the smallest amount of work
/// that is still useful and returns; everything else happens elsewhere.
///
/// The three things that make this survive in the wild, all learned the hard way
/// by every project that has done this (docs/04-PLATFORM.md §1.4):
///   1. `.tapDisabledByTimeout` / `.tapDisabledByUserInput` must re-enable the tap.
///   2. A watchdog must check `tapIsEnabled`, because a non-nil tap is not a live tap.
///   3. Waking from sleep and switching sessions must re-check both.
final class KeyTapService {

    // MARK: - Observable state (single-writer counters, see AtomicCounter)

    let keyDownCount = AtomicCounter()
    let flagsChangedCount = AtomicCounter()
    /// keyDown events seen while Secure Input was on. Must stay at zero forever —
    /// if this ever moves, our central safety claim is false.
    let keyDownDuringSecureInput = AtomicCounter()
    /// flagsChanged seen while Secure Input was on. Expected to grow: this is the
    /// asymmetry that makes an unguarded double-Shift hotkey dangerous.
    let flagsChangedDuringSecureInput = AtomicCounter()
    let timeoutDisableCount = AtomicCounter()
    let userInputDisableCount = AtomicCounter()
    let watchdogRevivalCount = AtomicCounter()

    /// Last key seen, for the M0 diagnostics window. Memory only: never logged,
    /// never written to disk, wiped when Secure Input turns on (CLAUDE.md rule 1).
    let lastKeyCode = AtomicCounter(UInt64.max)
    let lastFlags = AtomicCounter()

    /// Milliseconds to stall inside the callback. Used only by the M0 experiment
    /// that measures where macOS decides we are too slow. Written by the UI,
    /// read by the tap thread; a single aligned word, so no lock (rule 7).
    let injectedStallMilliseconds = AtomicCounter()
    /// Same, but applied to our own synthetic events. M0 sweep only.
    let sweepStallMilliseconds = AtomicCounter()

    /// Mirror of `IsSecureEventInputEnabled()`, refreshed by SecureInputMonitor.
    /// The callback must not call into Carbon itself, so it reads this instead.
    let secureInputMirror = AtomicCounter()

    private(set) var isRunning = false

    // MARK: - Private

    private var thread: Thread?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var watchdog: CFRunLoopTimer?

    /// Marks events we post ourselves, so we never re-process our own typing.
    static let syntheticMarker: Int64 = 0x4C5A_5357   // "LZSW"

    // MARK: - Lifecycle

    func start() -> Bool {
        guard !isRunning else { return true }
        guard Permissions.current(runProbe: false).isUsable else { return false }

        let ready = DispatchSemaphore(value: 0)
        var created = false

        let t = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            created = self.installTap()
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            guard created else { return }
            CFRunLoopRun()
        }
        t.name = "com.lazyswitcher.eventtap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t

        ready.wait()
        isRunning = created
        if created { subscribeToSystemEvents() }
        return created
    }

    func stop() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.teardownTap()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        isRunning = false
    }

    // MARK: - Tap plumbing (runs on the tap thread)

    private func installTap() -> Bool {
        // Keyboard events only. CGEvent.h documents that bits we lack the
        // privilege for are silently cleared from the mask; asking for nothing
        // else means a denial shows up as a nil tap rather than as a live tap
        // that never sees a key.
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue)
                             | (1 << CGEventType.flagsChanged.rawValue))

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<KeyTapService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        // .commonModes, not .defaultMode: otherwise the tap goes deaf while a menu
        // is open or a window is being resized.
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        installWatchdog()
        return true
    }

    private func installWatchdog() {
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 5, 5, 0, 0
        ) { [weak self] _ in self?.checkTapAlive() }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        watchdog = timer
    }

    private func checkTapAlive() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            watchdogRevivalCount.bump()
        }
    }

    private func teardownTap() {
        if let watchdog { CFRunLoopTimerInvalidate(watchdog) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        watchdog = nil; runLoopSource = nil; tap = nil
    }

    // MARK: - The hot path

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 1. Our own synthetic events, first line, before anything else.
        //    Without this the corrections we type feed straight back in.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            // M0 only: the timeout sweep drives the callback with events it posts
            // itself, so it needs to stall here, on the one path that is otherwise
            // a straight passthrough. Armed by nothing in a real build.
            let sweepStall = sweepStallMilliseconds.value
            if sweepStall > 0 { usleep(useconds_t(sweepStall * 1000)) }
            return Unmanaged.passUnretained(event)
        }

        // 2. The system telling us we were too slow, or that the user took over.
        //    Re-enable, never re-create.
        if type == .tapDisabledByTimeout {
            timeoutDisableCount.bump()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        if type == .tapDisabledByUserInput {
            userInputDisableCount.bump()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        // 3. Deliberate stall, M0 experiment only. Zero in every real build.
        let stall = injectedStallMilliseconds.value
        if stall > 0 { usleep(useconds_t(stall * 1000)) }

        let secure = secureInputMirror.value != 0

        switch type {
        case .keyDown:
            keyDownCount.bump()
            if secure {
                // Should be unreachable. Counted rather than asserted, because
                // the whole safety story rests on it and we want evidence.
                keyDownDuringSecureInput.bump()
            } else {
                // Autorepeat would otherwise flood the buffer.
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    lastKeyCode.value = UInt64(event.getIntegerValueField(.keyboardEventKeycode))
                    lastFlags.value = UInt64(event.flags.rawValue)
                }
            }
        case .flagsChanged:
            flagsChangedCount.bump()
            // These keep arriving while Secure Input is on. Any hotkey built on
            // them must check Secure Input first, or it fires mid-password.
            if secure { flagsChangedDuringSecureInput.bump() }
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    /// Called when Secure Input turns on: nothing typed may outlive it.
    func wipeVolatileState() {
        lastKeyCode.value = UInt64.max
        lastFlags.value = 0
    }

    // MARK: - Waking up

    private func subscribeToSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.didWakeNotification,
                                          NSWorkspace.sessionDidBecomeActiveNotification,
                                          NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reviveAfterSystemEvent()
            }
        }
    }

    private func reviveAfterSystemEvent() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.checkTapAlive()
        }
        CFRunLoopWakeUp(runLoop)
    }
}
