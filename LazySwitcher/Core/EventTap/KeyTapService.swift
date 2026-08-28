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

    // MARK: - Collaborators owned by the tap thread

    /// Both are touched only from the tap thread, so neither needs a lock.
    private let wordBuffer = WordBuffer()
    private let hotkeyDetector = HotkeyDetector()

    /// A word just ended. Delivered on `decideQueue`, never on the tap thread.
    var onWordCommitted: (([KeyRecord], UInt16) -> Void)?
    /// A hotkey fired. Delivered on the main queue.
    var onHotkey: ((HotkeyDetector.Event) -> Void)?

    /// The buffer was cleared for a reason other than a word ending. Whoever is
    /// remembering recent words has to forget them too: our knowledge of where
    /// the text is has just expired.
    var onBufferInvalidated: ((WordBuffer.ResetReason) -> Void)?

    private let decideQueue = DispatchQueue(label: "com.lazyswitcher.decide", qos: .userInitiated)

    /// Mach absolute time of the last keystroke, for the idle timeout.
    private let lastKeystrokeTime = AtomicCounter()

    /// Bumped on every event that can move the caret or change the text.
    ///
    /// A decision travels through three asynchronous hops before it becomes a
    /// replacement — tap thread, decide queue, main, apply queue — and up to a
    /// second can pass. If anything was typed in between, the characters in
    /// front of the caret are no longer the ones the decision was about, and
    /// deleting that many of them eats somebody else's text. Readable from any
    /// thread for the cost of a load, so the check is free.
    let inputGeneration = AtomicCounter()

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
        let now = mach_absolute_time()

        switch type {
        case .keyDown:
            keyDownCount.bump()
            if secure {
                // Should be unreachable: under Secure Input the OS stops
                // delivering these to every tap in the system. Counted rather
                // than asserted, because the whole safety story rests on it and
                // evidence beats belief.
                keyDownDuringSecureInput.bump()
                wordBuffer.wipe(reason: .secureInput)
                hotkeyDetector.reset()
                break
            }

            // A held-down key repeats, and every repeat changes the screen.
            //
            // Ignoring repeats entirely was wrong in a way that only shows up
            // afterwards: the text grew or shrank while our picture of it stood
            // still, and `inputGeneration` — the very counter that is supposed
            // to catch "the text moved under us" — did not advance either, so
            // every staleness check passed on stale data. A held Backspace is
            // the bad case: characters disappear, the buffer still believes they
            // are there, and the next replacement deletes that many from a caret
            // that has moved.
            //
            // We cannot reconstruct what repeated, so we do not try. The
            // generation advances, which invalidates anything in flight, and the
            // buffer is dropped, which is the honest answer to "what is on
            // screen now" — we no longer know.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                inputGeneration.bump()
                wordBuffer.wipe(reason: .caretMoved)
                if let handler = onBufferInvalidated {
                    DispatchQueue.main.async { handler(.caretMoved) }
                }
                break
            }

            expireBufferIfIdle(now: now)
            lastKeystrokeTime.value = now
            inputGeneration.bump()

            lastKeyCode.value = UInt64(event.getIntegerValueField(.keyboardEventKeycode))
            lastFlags.value = UInt64(event.flags.rawValue)

            hotkeyDetector.noteKeyDown()

            let flags = event.flags
            let chord = flags.contains(.maskCommand)
                     || flags.contains(.maskControl)
                     || flags.contains(.maskAlternate)
            let record = KeyRecord(event: event, timestamp: now)

            let outcome = wordBuffer.append(record, hasCommandControlOrOption: chord)
            if case .reset(let reason) = outcome, let handler = onBufferInvalidated {
                DispatchQueue.main.async { handler(reason) }
            }
            if case .boundary(let word, let terminator) = outcome {
                // Hand off and get out. Scoring, dictionaries and anything that
                // could block belong on the other queue.
                if let handler = onWordCommitted {
                    decideQueue.async { handler(word, terminator) }
                }
            }

        case .flagsChanged:
            flagsChangedCount.bump()
            // These keep arriving while Secure Input is on — that asymmetry is
            // why every modifier-based hotkey is gated on it.
            if secure {
                flagsChangedDuringSecureInput.bump()
                wordBuffer.wipe(reason: .secureInput)
            }
            let seconds = Double(now) * Self.machToSeconds
            if let fired = hotkeyDetector.handleFlagsChanged(flags: event.flags,
                                                            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                                                            timestamp: seconds,
                                                            secureInputActive: secure),
               let handler = onHotkey {
                DispatchQueue.main.async { handler(fired) }
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    /// Ten seconds without typing and we no longer believe the caret is where we
    /// left it — the user has been reading, clicking elsewhere, switching apps.
    private func expireBufferIfIdle(now: UInt64) {
        let previous = lastKeystrokeTime.value
        guard previous != 0 else { return }
        let elapsed = Double(now - previous) * Self.machToSeconds
        if elapsed > 10 { wordBuffer.wipe(reason: .idleTimeout) }
    }

    /// Mach ticks to seconds. Computed once: on Apple Silicon the ratio is not 1.
    private static let machToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    // MARK: - Invalidating the buffer from outside

    /// Changes the gesture. Hops to the tap thread: the detector belongs to it.
    func setHotkeyStyle(_ style: HotkeyStyle) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.hotkeyDetector.config.style = style
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Reads what the hotkey may act on: the word being typed, or the one just
    /// finished. Both come from the same hop to the tap thread, so they cannot
    /// disagree with each other — asking twice could see a keystroke land in
    /// between and act on a caret position that no longer exists.
    struct HotkeyTarget {
        let inProgress: [KeyRecord]
        let justCommitted: (keys: [KeyRecord], terminator: UInt16)?
    }

    func requestHotkeyTarget(_ completion: @escaping (HotkeyTarget) -> Void) {
        guard let runLoop else { completion(HotkeyTarget(inProgress: [], justCommitted: nil)); return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            let target = HotkeyTarget(inProgress: self?.wordBuffer.currentWord ?? [],
                                      justCommitted: self?.wordBuffer.justCommitted)
            DispatchQueue.main.async { completion(target) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Drops the in-progress word after we have replaced it on screen, so the
    /// buffer and the text agree again.
    func clearBufferAfterReplacement() {
        invalidateBuffer(reason: .replacementApplied)
    }

    /// Called by the mouse monitor, focus monitor and Secure Input monitor.
    /// Hops to the tap thread, because the buffer belongs to it.
    func invalidateBuffer(reason: WordBuffer.ResetReason) {
        inputGeneration.bump()
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.wordBuffer.wipe(reason: reason)
            self?.hotkeyDetector.reset()
        }
        CFRunLoopWakeUp(runLoop)
        if let handler = onBufferInvalidated {
            DispatchQueue.main.async { handler(reason) }
        }
    }

    /// Called when Secure Input turns on: nothing typed may outlive it.
    func wipeVolatileState() {
        lastKeyCode.value = UInt64.max
        lastFlags.value = 0
        invalidateBuffer(reason: .secureInput)
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
