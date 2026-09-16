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

    /// Bumped by the watchdog every time it has looked at the tap and found it
    /// alive. Written only from the tap thread, read from the main thread.
    ///
    /// The watchdog can only rescue a tap whose thread is still running. If that
    /// thread dies or wedges, the watchdog dies with it and nothing is left to
    /// notice — the application keeps running, the icon stays in the menu bar,
    /// and no keystroke ever reaches us again. This counter is how the main
    /// thread can tell the difference between "quiet" and "gone".
    let watchdogTick = AtomicCounter()

    /// How many times the tap had to be built again from nothing.
    let tapRebuildCount = AtomicCounter()
    /// Times a created tap port could not be turned into a run-loop source.
    let sourceCreationFailures = AtomicCounter()

    /// Events that arrived through a tap the service no longer stands behind.
    ///
    /// Each one is a keystroke that used to be put into the word buffer a
    /// second time. Written only by threads that are on their way out, so an
    /// increment can occasionally be lost; the only question it answers is
    /// "has this ever happened", and a lost increment does not change that.
    let staleDeliveries = AtomicCounter()
    /// Times `stop()` gave up waiting for the old tap thread to clean up.
    /// Main thread only.
    let stopsTimedOut = AtomicCounter()
    /// Times a starting tap thread did not report back in time. Main only.
    let startsTimedOut = AtomicCounter()

    /// Which keystrokes put sentence punctuation on screen, as a bitmap.
    ///
    /// Indexed by `keyCode * 2 + (shift ? 1 : 0)`, so 128 key codes and both
    /// shift states fit in 256 bits — four aligned 64-bit words, which are read
    /// atomically on this hardware without a lock (see `AtomicCounter`). The tap
    /// callback must not take a lock the main thread can hold, and it must not
    /// call into TIS or the layout tables at all, so the answer is computed on
    /// the main thread whenever the layout changes and left here for the
    /// callback to look up in one instruction.
    private let punctuationBitmap = (AtomicCounter(), AtomicCounter(),
                                     AtomicCounter(), AtomicCounter())

    /// Replaces the bitmap. Main thread only; the callback only reads it.
    func setSentencePunctuation(_ keys: Set<UInt32>) {
        var words: [UInt64] = [0, 0, 0, 0]
        for index in keys where index < 256 {
            words[Int(index) / 64] |= (1 << UInt64(index % 64))
        }
        punctuationBitmap.0.value = words[0]
        punctuationBitmap.1.value = words[1]
        punctuationBitmap.2.value = words[2]
        punctuationBitmap.3.value = words[3]
    }

    private func endsSentence(_ record: KeyRecord) -> Bool {
        guard record.keyCode < 128 else { return false }
        let index = Int(record.keyCode) * 2 + (record.shift ? 1 : 0)
        let word: UInt64
        switch index / 64 {
        case 0: word = punctuationBitmap.0.value
        case 1: word = punctuationBitmap.1.value
        case 2: word = punctuationBitmap.2.value
        default: word = punctuationBitmap.3.value
        }
        return word & (1 << UInt64(index % 64)) != 0
    }

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

    // MARK: - Delivered elsewhere

    /// A word just ended. Delivered on `decideQueue`, never on the tap thread.
    var onWordCommitted: (([KeyRecord], KeyRecord) -> Void)?
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

    /// Diagnostics only: how many of our own events came back through the tap
    /// and were discarded. A number far from the expected one means the marker
    /// is not doing its job, which is worth being able to see rather than infer.
    let ownEventsDiscarded = AtomicCounter()

    /// Main thread only.
    private(set) var isRunning = false

    // MARK: - Private

    /// One tap thread and everything it created.
    ///
    /// This type is the fix for letters coming out doubled. The tap, its
    /// run-loop source and its watchdog used to be properties of the service,
    /// and a restart ran two threads over them at once: the old one tearing
    /// down "the tap" while the new one was installing "the tap". Depending on
    /// who got there first, the old thread tore down its successor's tap, or
    /// wrote nil over the reference to a tap that was still installed — which
    /// then could never be removed, and went on delivering every keystroke a
    /// second time into the same word buffer. `сообщение` was scored as
    /// `ссооооббщщееннииее`, found to read better in Latin, and replaced.
    ///
    /// Measured on the reporting machine before the fix: two enabled taps
    /// owned by one Lazy Switcher process, serviced by a single tap thread that
    /// had been created long after launch.
    ///
    /// Now each thread owns its own instance. Nothing here is shared: a thread
    /// creates its tap, services it and tears it down, and no other thread ever
    /// reads or writes these fields — so a thread being replaced can neither
    /// touch its successor's tap nor lose track of its own.
    final class TapThread {
        /// Identifies the thread to the tap callback. Assigned by the main
        /// thread before the thread starts, never changed.
        let serial: UInt64
        let service: KeyTapService
        /// Set once by the main thread when the service moves on; read here.
        let retired = AtomicCounter()

        /// The word being typed and the gesture in progress.
        ///
        /// Owned by this thread, not by the service. They used to belong to the
        /// service, and the half-second `stop()` is allowed to give up waiting
        /// — on a thread that is most likely late precisely because it is
        /// inside the callback, which is where the buffer is written. The
        /// incoming thread then started by wiping that same buffer. Two threads,
        /// one buffer, again. A thread that is being replaced now writes only
        /// into storage nobody else will ever look at.
        let buffer = WordBuffer()
        let detector = HotkeyDetector()
        /// Written by this thread before it signals readiness, read by the
        /// main thread only after that.
        private(set) var runLoop: CFRunLoop?
        fileprivate(set) var isInstalled = false

        // This thread only.
        fileprivate var port: CFMachPort?
        fileprivate var source: CFRunLoopSource?
        fileprivate var watchdog: CFRunLoopTimer?

        init(serial: UInt64, service: KeyTapService, hotkeyStyle: HotkeyStyle? = nil) {
            self.serial = serial
            self.service = service
            // Set here, on the thread that creates this, before the tap thread
            // exists — so the gesture the user chose survives a restart without
            // anybody reading it across threads.
            if let hotkeyStyle { detector.config.style = hotkeyStyle }
        }

        fileprivate func run(ready: DispatchSemaphore) {
            runLoop = CFRunLoopGetCurrent()
            // Nothing to clear: this thread's buffer is its own and starts
            // empty, which is also the honest description of what we know about
            // the text after a gap in listening.
            isInstalled = service.installTap(on: self)
            if isInstalled { service.installWatchdog(on: self) }
            ready.signal()
            guard isInstalled else { return }
            CFRunLoopRun()
            // However the loop ended — stopped on purpose, or left with nothing
            // to run — nothing this thread made may outlive it.
            service.teardown(self)
        }
    }

    /// The tap thread the service currently stands behind. Main thread only.
    private var current: TapThread?
    private var nextSerial: UInt64 = 0
    /// `current`'s serial, for the tap callback to compare against. Written by
    /// the main thread only; zero while nothing is running.
    let activeSerial = AtomicCounter()
    /// The gesture the user chose, re-applied to every new tap thread.
    private var hotkeyStyle: HotkeyStyle?
    private var subscribedToSystemEvents = false

    /// Marks events we post ourselves, so we never re-process our own typing.
    static let syntheticMarker: Int64 = 0x4C5A_5357   // "LZSW"

    // MARK: - Lifecycle

    /// Main thread only.
    func start() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning else { return true }
        // No preflight check here.
        //
        // `CGPreflight*` answers from a per-process cache that never refreshes
        // (Н6), so in a process that started without access it says "no" forever
        // — including after the user grants it, and including when this is a
        // restart after the tap died. Refusing to even try on that answer is how
        // a recoverable failure becomes permanent.
        //
        // `CGEvent.tapCreate` asks the system itself, returns nil on refusal and
        // shows nothing to the user, so it is both the honest answer and a safe
        // one to ask for.

        nextSerial += 1
        let owner = TapThread(serial: nextSerial, service: self)
        // Active before its tap even exists, so that its first event counts —
        // and so that, in the same instant, every thread before it stops
        // counting.
        activeSerial.value = owner.serial

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { owner.run(ready: ready) }
        thread.name = "com.lazyswitcher.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Bounded, because `tapCreate` is a synchronous round trip to the
        // window server and this is the main thread. An unbounded wait here
        // freezes the menu bar — the one way into this application — for as
        // long as the window server takes to answer, which after a wake can be
        // a while and, if it never answers, is forever.
        if ready.wait(timeout: .now() + 3) == .timedOut {
            // Do not read anything the thread may still be writing. Disown it
            // instead: whatever tap it opens is stale from birth, its own
            // watchdog removes it, and the heartbeat tries again.
            activeSerial.value = 0
            startsTimedOut.bump()
            return false
        }

        guard owner.isInstalled else {
            if activeSerial.value == owner.serial { activeSerial.value = 0 }
            return false
        }
        current = owner
        isRunning = true
        subscribeToSystemEvents()
        if let hotkeyStyle { setHotkeyStyle(hotkeyStyle) }
        return true
    }

    /// Main thread only.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        isRunning = false
        guard let owner = current else { return }
        current = nil
        // From here on nothing the old thread delivers is acted on, whether or
        // not it ever gets round to cleaning up.
        if activeSerial.value == owner.serial { activeSerial.value = 0 }
        owner.retired.value = 1
        guard let runLoop = owner.runLoop else { return }

        let finished = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            owner.service.teardown(owner)
            CFRunLoopStop(CFRunLoopGetCurrent())
            finished.signal()
        }
        CFRunLoopWakeUp(runLoop)
        // Worth a short wait. A thread that is alive answers in microseconds,
        // and waiting means its tap is gone before a replacement exists. A
        // wedged thread does not answer at all, and freezing the menu bar on
        // it would help nobody — it cleans up after itself if it ever wakes,
        // and until then the serial check keeps its events out of the buffer.
        if finished.wait(timeout: .now() + 0.5) == .timedOut {
            stopsTimedOut.bump()
        }
    }

    /// Asks the tap thread to check its tap now, rather than at its next
    /// watchdog pass. Main thread only.
    ///
    /// Also the way to tell a quiet thread from a gone one: an alive thread
    /// answers by advancing `watchdogTick`, a wedged one does not.
    func checkAlive() {
        performOnTapThread { owner in owner.service.checkTapAlive(owner) }
    }

    /// Runs `work` on the tap thread the service currently stands behind, and
    /// only there. Main thread only.
    ///
    /// The buffer and the hotkey detector belong to that thread. A block that
    /// was queued for a thread the service has since moved away from would be
    /// touching them from the wrong thread, at the same time as the right one,
    /// so it checks first and quietly does nothing.
    @discardableResult
    func performOnTapThread(_ work: @escaping (TapThread) -> Void,
                            ifNotRun fallback: (() -> Void)? = nil) -> Bool {
        // `current` is main-thread state, and it is a strong reference: reading
        // it from anywhere else would be a race on the reference itself, not
        // merely a stale answer.
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = current, let runLoop = owner.runLoop else {
            fallback?()
            return false
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            guard owner.retired.value == 0,
                  owner.service.activeSerial.value == owner.serial else {
                if let fallback { DispatchQueue.main.async(execute: fallback) }
                return
            }
            work(owner)
        }
        CFRunLoopWakeUp(runLoop)
        return true
    }

    // MARK: - Counting taps

    /// Keyboard taps installed by this process, according to the window server.
    ///
    /// The truth, as opposed to what our own bookkeeping believes — which is
    /// exactly what went wrong: the service held a reference to one tap while
    /// the system was delivering keystrokes to two. Diagnostics and tests only;
    /// it is a round trip to the window server.
    static func tapsInstalledByThisProcess() -> Int {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return 0 }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return 0 }
        let pid = getpid()
        let keyDown = CGEventMask(1 << CGEventType.keyDown.rawValue)
        return list.prefix(Int(count)).filter {
            $0.tappingProcess == pid && $0.eventsOfInterest & keyDown != 0
        }.count
    }

    // MARK: - Tap plumbing (runs on the tap thread)

    fileprivate func installTap(on owner: TapThread) -> Bool {
        // Keyboard events only. CGEvent.h documents that bits we lack the
        // privilege for are silently cleared from the mask; asking for nothing
        // else means a denial shows up as a nil tap rather than as a live tap
        // that never sees a key.
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue)
                             | (1 << CGEventType.flagsChanged.rawValue))

        // The callback is told which thread's tap delivered the event, not just
        // which service it belongs to. `owner` outlives the port: the thread
        // holds it until it exits, and the port is invalidated before that.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<TapThread>.fromOpaque(refcon).takeUnretainedValue()
                return owner.service.handle(type: type, event: event, from: owner)
            },
            userInfo: Unmanaged.passUnretained(owner).toOpaque()
        ) else { return false }

        // A port is not a source, and the conversion can fail.
        //
        // `CFMachPortCreateRunLoopSource` returns NULL for a port that is already
        // invalid — which a freshly created tap can be, because creating it and
        // being allowed to keep it are two different things. Swift types the
        // result as optional and `CFRunLoopAddSource` as implicitly unwrapped, so
        // nothing here objected: the nil went straight into C and the process
        // died on the spot, on the tap thread, taking the whole application with
        // it.
        //
        // Reported as "the app does not work at all", which was exactly right —
        // it was crashing at launch. The crash report says:
        //
        //     EXC_BAD_ACCESS (SIGSEGV) in CFRunLoopAddSource
        //     ← KeyTapService.installTap()  ← com.lazyswitcher.eventtap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            sourceCreationFailures.bump()
            return false
        }
        owner.port = port
        owner.source = source
        // .commonModes, not .defaultMode: otherwise the tap goes deaf while a menu
        // is open or a window is being resized.
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// One per thread, for the life of the thread — not per tap. A rebuild that
    /// fails keeps the watchdog, so the thread tries again five seconds later
    /// instead of going quiet with nothing left to notice.
    fileprivate func installWatchdog(on owner: TapThread) {
        // Same shape of hazard as above: a nil timer handed to CFRunLoopAddTimer
        // is a crash, and nothing in the types says so.
        let created = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 5, 5, 0, 0
        ) { _ in owner.service.checkTapAlive(owner) }
        guard let timer = created else { return }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        owner.watchdog = timer
    }

    fileprivate func checkTapAlive(_ owner: TapThread) {
        // A thread the service has moved on from repairs nothing. It removes
        // what it made and ends — otherwise it would faithfully rebuild a tap
        // for a service that is listening to somebody else, and that second
        // tap is the whole bug.
        guard owner.retired.value == 0, activeSerial.value == owner.serial else {
            teardown(owner)
            CFRunLoopStop(CFRunLoopGetCurrent())
            return
        }

        // A tap that is gone, or whose mach port has died under us, cannot be
        // re-enabled — `tapEnable` on a dead port succeeds silently and changes
        // nothing. The previous version only ever tried to re-enable, so once
        // the port died the application was deaf for the rest of the session
        // while its watchdog reported success every five seconds.
        guard let port = owner.port, CFMachPortIsValid(port) else { rebuildTap(owner); return }

        if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
            watchdogRevivalCount.bump()
            // Verify rather than assume. If it did not come back, the port is
            // no longer usable whatever it claims about itself.
            guard CGEvent.tapIsEnabled(tap: port) else { rebuildTap(owner); return }
        }
        watchdogTick.bump()
    }

    /// Throws this thread's tap away and builds a new one on the same run loop.
    ///
    /// Runs on the tap thread, from inside the watchdog's callback. The
    /// watchdog itself stays.
    private func rebuildTap(_ owner: TapThread) {
        teardownTap(owner)
        guard installTap(on: owner) else { return }
        tapRebuildCount.bump()
        watchdogTick.bump()
        // We were not listening while this was being rebuilt.
        noteInputMissed(owner)
    }

    /// Everything, from the thread up. The last resort, driven from the main
    /// thread when the tap thread has stopped answering.
    func restart() -> Bool {
        stop()
        return start()
    }

    /// Removes this thread's tap. Its own thread only.
    private func teardownTap(_ owner: TapThread) {
        if let port = owner.port {
            CGEvent.tapEnable(tap: port, enable: false)
            if let source = owner.source {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CFMachPortInvalidate(port)
        }
        owner.source = nil
        owner.port = nil
    }

    /// Removes everything this thread made. Its own thread only; safe to repeat.
    fileprivate func teardown(_ owner: TapThread) {
        if let watchdog = owner.watchdog { CFRunLoopTimerInvalidate(watchdog) }
        owner.watchdog = nil
        teardownTap(owner)
    }

    // MARK: - The hot path

    /// Internal rather than private so tests can deliver events from a tap
    /// that is, or is not, the one the service stands behind.
    func handle(type: CGEventType, event: CGEvent, from owner: TapThread) -> Unmanaged<CGEvent>? {
        // 1. Our own synthetic events, first line, before anything else.
        //    Without this the corrections we type feed straight back in.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            ownEventsDiscarded.bump()
            // M0 only: the timeout sweep drives the callback with events it posts
            // itself, so it needs to stall here, on the one path that is otherwise
            // a straight passthrough. Armed by nothing in a real build.
            #if DEBUG
            let sweepStall = sweepStallMilliseconds.value
            if sweepStall > 0 { usleep(useconds_t(sweepStall * 1000)) }
            #endif
            return Unmanaged.passUnretained(event)
        }

        // 2. Only the tap the service currently stands behind may act.
        //
        //    However a second tap came to exist — a restart that lost a race, a
        //    thread that woke up after being replaced, a path nobody has thought
        //    of yet — its events go through untouched and nothing is recorded.
        //    Two taps in one process is a performance problem; two taps writing
        //    into one buffer is every word typed twice. One load and a compare.
        //
        //    Also not re-enabled if the system disabled it: a stale tap is
        //    better off disabled.
        guard owner.serial == activeSerial.value else {
            staleDeliveries.bump()
            return Unmanaged.passUnretained(event)
        }

        // 3. The system telling us we were too slow, or that the user took over.
        //    Re-enable, never re-create.
        if type == .tapDisabledByTimeout {
            timeoutDisableCount.bump()
            if let port = owner.port { CGEvent.tapEnable(tap: port, enable: true) }
            noteInputMissed(owner)
            return nil
        }
        if type == .tapDisabledByUserInput {
            userInputDisableCount.bump()
            if let port = owner.port { CGEvent.tapEnable(tap: port, enable: true) }
            noteInputMissed(owner)
            return nil
        }

        // 4. Deliberate stall, M0 experiment only.
        //
        // Compiled out of Release rather than left at zero. Nothing in a shipped
        // build can arm it — the triggers are debug-only and the release audit
        // checks they are absent — but this is the callback macOS times, and a
        // sleep on the path it times has no business existing there at all.
        #if DEBUG
        let stall = injectedStallMilliseconds.value
        if stall > 0 { usleep(useconds_t(stall * 1000)) }
        #endif

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
                owner.buffer.wipe(reason: .secureInput)
                owner.detector.reset()
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
                owner.buffer.wipe(reason: .caretMoved)
                if let handler = onBufferInvalidated {
                    DispatchQueue.main.async { handler(.caretMoved) }
                }
                break
            }

            expireBufferIfIdle(owner, now: now)
            lastKeystrokeTime.value = now
            inputGeneration.bump()

            lastKeyCode.value = UInt64(event.getIntegerValueField(.keyboardEventKeycode))
            lastFlags.value = UInt64(event.flags.rawValue)

            owner.detector.noteKeyDown()

            let flags = event.flags
            let chord = flags.contains(.maskCommand)
                     || flags.contains(.maskControl)
                     || flags.contains(.maskAlternate)
            let record = KeyRecord(event: event, timestamp: now)

            let outcome = owner.buffer.append(record, hasCommandControlOrOption: chord,
                                              endsSentence: endsSentence(record))
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
                owner.buffer.wipe(reason: .secureInput)
            }
            let seconds = Double(now) * Self.machToSeconds
            if let fired = owner.detector.handleFlagsChanged(flags: event.flags,
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
    private func expireBufferIfIdle(_ owner: TapThread, now: UInt64) {
        let previous = lastKeystrokeTime.value
        guard previous != 0 else { return }
        let elapsed = Double(now - previous) * Self.machToSeconds
        if elapsed > 10 { owner.buffer.wipe(reason: .idleTimeout) }
    }

    /// Mach ticks to seconds. Computed once: on Apple Silicon the ratio is not 1.
    private static let machToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    // MARK: - Invalidating the buffer from outside

    /// Changes the gesture. Hops to the tap thread: the detector belongs to it.
    ///
    /// Remembered as well, so a tap thread started later — after a restart, or
    /// once permission arrives — comes up with the gesture the user chose
    /// rather than the default.
    func setHotkeyStyle(_ style: HotkeyStyle) {
        hotkeyStyle = style
        performOnTapThread { owner in owner.detector.config.style = style }
    }

    /// Reads what the hotkey may act on: the word being typed, or the one just
    /// finished. Both come from the same hop to the tap thread, so they cannot
    /// disagree with each other — asking twice could see a keystroke land in
    /// between and act on a caret position that no longer exists.
    struct HotkeyTarget {
        let inProgress: [KeyRecord]
        let justCommitted: (keys: [KeyRecord], terminator: KeyRecord)?
    }

    func requestHotkeyTarget(_ completion: @escaping (HotkeyTarget) -> Void) {
        // Nothing to act on is still an answer. Without one the hotkey would
        // wait forever for a thread that was replaced while it asked.
        let nothing = { completion(HotkeyTarget(inProgress: [], justCommitted: nil)) }
        performOnTapThread({ owner in
            let buffer = owner.buffer
            let target = HotkeyTarget(inProgress: buffer.currentWord,
                                      justCommitted: buffer.justCommitted)
            DispatchQueue.main.async { completion(target) }
        }, ifNotRun: nothing)
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
        performOnTapThread { owner in
            // Only the word buffer. It is a claim about text sitting on screen,
            // and a caret that moved makes it false.
            //
            // The hotkey detector is not that kind of state — it is a claim
            // about which keys a person is holding right now, and moving the
            // caret does not let go of their Shift. Resetting it here meant that
            // in applications which emit focus notifications in bursts (every
            // Electron application, every browser) a gesture in progress was
            // wiped between the two taps, and the hotkey "did nothing" for
            // reasons the person had no way to see. It is reset where it should
            // be: when Secure Input turns on.
            owner.buffer.wipe(reason: reason)
        }
        if let handler = onBufferInvalidated {
            DispatchQueue.main.async { handler(reason) }
        }
    }

    /// Called when Secure Input turns on: nothing typed may outlive it.
    func wipeVolatileState() {
        lastKeyCode.value = UInt64.max
        lastFlags.value = 0
        performOnTapThread { owner in owner.detector.reset() }
        invalidateBuffer(reason: .secureInput)
    }

    /// Keystrokes happened and we did not see them.
    ///
    /// Every recovery path arrives here: macOS disabled the tap for being slow
    /// or for user input, or the tap had to be built again. In all of them the
    /// application comes back listening — and holding a description of the text
    /// on screen that was accurate before the gap and is a guess after it. Acting
    /// on that guess means deleting characters somebody else put there, which is
    /// the expensive kind of mistake; saying "I lost track" costs one missed
    /// correction.
    ///
    /// Runs on the tap thread, which is the thread that owns the buffer.
    private func noteInputMissed(_ owner: TapThread) {
        owner.buffer.wipe(reason: .caretMoved)
        inputGeneration.bump()
        if let handler = onBufferInvalidated {
            DispatchQueue.main.async { handler(.caretMoved) }
        }
    }

    // MARK: - Waking up

    /// Once per service, not once per start. Every restart used to add another
    /// set of observers, so each wake asked every thread ever started to check
    /// "the tap" — all of them the same one, from whichever thread got there.
    private func subscribeToSystemEvents() {
        guard !subscribedToSystemEvents else { return }
        subscribedToSystemEvents = true
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.didWakeNotification,
                                          NSWorkspace.sessionDidBecomeActiveNotification,
                                          NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.checkAlive()
            }
        }
    }
}
