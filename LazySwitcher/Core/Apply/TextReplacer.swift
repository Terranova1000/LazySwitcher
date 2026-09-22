import AppKit
import ApplicationServices

/// Swaps a word the user has already typed for its other-layout reading.
///
/// Two ways of doing it, and the choice is per app rather than global:
///
/// · **Accessibility** — set the selected range, then the selected text. One
///   operation, instant, keeps the app's own undo intact. Works in native
///   AppKit fields and nowhere else. Its failure mode is the nastiest kind:
///   it returns success and does nothing at all, so the result is verified.
/// · **Synthetic typing** — backspaces followed by the replacement. Works
///   nearly everywhere, but it is N events with pauses between them, and some
///   apps race it with their own autocomplete.
///
/// Deliberately absent: the pasteboard. It works almost everywhere, and users
/// hate it — it pollutes clipboard history, syncs to the iPhone via Universal
/// Clipboard, and needs a fragile delay to restore. "Never touches your
/// clipboard" is a feature worth keeping.
final class TextReplacer {

    enum Strategy: String {
        case accessibility
        case synthetic
    }

    struct Outcome {
        let strategy: Strategy
        let succeeded: Bool
        /// The text moved while we were getting ready, so nothing was typed.
        var abandonedLate = false
        /// There was less text in front of the caret than we meant to replace.
        ///
        /// Our idea of the text is too long, not the application's answer wrong,
        /// so the useful response is to try again with less of it rather than to
        /// give up on the word entirely.
        var runDidNotFit = false
        /// How much text there actually was, when we managed to measure it.
        ///
        /// The retry has to fit inside this. Retrying blindly with "just the
        /// current word" was still a guess, and a guess that deletes is the one
        /// kind this project does not get to make.
        var availableBeforeCaret: Int?
    }

    /// What the accessibility route concluded.
    ///
    /// The distinction between the last two is the whole point. "This app does
    /// not support it" means try something else. "I selected a range and it did
    /// not contain what I expected" means our idea of where the caret is, is
    /// wrong — and the fallback deletes a fixed number of characters *at the
    /// caret*. Treating the second as the first is how a correction eats a
    /// neighbouring word.
    private enum AccessibilityResult: Equatable {
        case replaced
        case notSupported
        case mismatch
        /// Fewer characters before the caret than the run we were asked to
        /// replace. Distinguished from `mismatch` because the cure is different:
        /// a mismatch says we cannot trust this route here, while this says we
        /// asked for too much and should ask for less.
        case tooLongForField
    }

    private let synthetic: SyntheticEventSource?
    var syntheticSource: SyntheticEventSource? { synthetic }

    /// Last few replacements: strategy, lengths, verdict. Lengths only — no
    /// text, ever (rule 1). Kept because the one thing that made the duplicated
    /// word tractable was seeing «ax:mismatch 7→7 | synth 14→14» written down;
    /// every hypothesis before that was guesswork.
    private(set) var history: [String] = []
    func clearHistory() { history.removeAll() }
    /// Why the last accessibility attempt gave up. Diagnostics only.
    private(set) var lastAXReason = "—"
    private func log(_ line: String) {
        history.append(line)
        if history.count > 12 { history.removeFirst() }
    }

    /// How long to let the app finish processing the keystroke that triggered
    /// us before looking at the text.
    ///
    /// We act on the space that ends a word, and many apps render it a frame or
    /// two later — so a query made immediately sees the text without that space,
    /// concludes the caret is one character short of where we expect, and calls
    /// it a mismatch. The synthetic route already waited for this reason; the
    /// accessibility route did not, and it read a field that had not caught up.
    var settleDelay: useconds_t = 25_000
    /// Apps where the accessibility route claimed success and changed nothing.
    /// Once burned we do not try it there again this session.
    /// Applications the accessibility route has failed in, and when.
    ///
    /// Timed rather than permanent. The entry used to be forever — `forget` was
    /// written for this and never called from anywhere — so one failure in an
    /// application meant every later replacement there went through synthetic
    /// typing, which sends a count of backspaces and cannot check what it is
    /// deleting. A single wrong guess about the text thus removed the one path
    /// that verifies itself, for the rest of the session.
    ///
    /// Applications also get better with time rather than worse: an accessibility
    /// tree that was not built when we first asked usually is later (Н35), so an
    /// answer from thirty seconds ago should not decide the next hour.
    /// Diagnostic: replacements found already applied when we looked again.
    private(set) var alreadyDone = 0
    /// Diagnostic: replacements dropped at the last moment because the person
    /// had typed on. Each one is a word not corrected and, more to the point,
    /// a word not damaged.
    private(set) var lateAbandons = 0
    /// Characters before the caret at the last "did not fit". Read once, by the
    /// outcome that reports it.
    private var lastAvailable: Int?

    private var accessibilityFailures: [String: Date] = [:]
    private static let failureMemory: TimeInterval = 60

    private func isBlacklisted(_ bundleID: String) -> Bool {
        guard let since = accessibilityFailures[bundleID] else { return false }
        guard Date().timeIntervalSince(since) < Self.failureMemory else {
            accessibilityFailures.removeValue(forKey: bundleID)
            return false
        }
        return true
    }

    init(synthetic: SyntheticEventSource? = SyntheticEventSource()) {
        self.synthetic = synthetic
    }

    #if DEBUG
    /// Forces the blind route, so it can be exercised where the verified one
    /// works. Every browser and every Electron application uses the blind one,
    /// and until now nothing tested it: in TextEdit, where the self-test types,
    /// accessibility always answers. Armed only through the M5 trigger file,
    /// which `scripts/audit-release.sh` checks is absent from release builds.
    var forceSyntheticForTesting = false
    #endif
    

    /// - Parameters:
    ///   - original: what is on screen now, exactly as typed.
    ///   - replacement: what should be there instead.
    ///   - bundleID: the frontmost app, for remembering what works where.
    /// - Parameter stillValid: asked again at the last moment before anything is
    ///   deleted. Between the decision and the first backspace lie a settle
    ///   delay, up to two accessibility round trips and a wait for the caret —
    ///   a tenth of a second in which somebody typing quickly has already put
    ///   the next letter on screen. Deleting a fixed number of characters then
    ///   eats that letter: «rfr ltkf» came back as «rкак ела», measured at
    ///   30 ms between keystrokes. The caller's generation counter knows; it
    ///   was simply never asked this late.
    @discardableResult
    func replace(original: String, with replacement: String, in bundleID: String,
                 stillValid: () -> Bool = { true },
                 silence: () -> Double = { KeyTapService.longSilence },
                 interval: () -> Double = { KeyTapService.slowestAssumedRhythm }) -> Outcome {
        usleep(settleDelay)

        var mayUseAccessibility = !isBlacklisted(bundleID)
        #if DEBUG
        if forceSyntheticForTesting { mayUseAccessibility = false }
        #endif
        if mayUseAccessibility {
            guard stillValid() else {
                log("поздно: текст уехал")
                lateAbandons += 1
                return Outcome(strategy: .accessibility, succeeded: false, abandonedLate: true)
            }
            var result = replaceViaAccessibility(original: original, with: replacement)
            if result == .mismatch {
                // Give it one more chance before concluding anything. A slow
                // app and a genuinely wrong idea of the text look identical
                // from one query, and treating a slow app as a broken one costs
                // that app the fast route forever.
                usleep(60_000)
                result = replaceViaAccessibility(original: original, with: replacement)
            }
            log("ax:\(result)[\(lastAXReason)] \(original.count)→\(replacement.count)")
            switch result {
            case .replaced:
                return Outcome(strategy: .accessibility, succeeded: true)
            case .mismatch:
                // The app answered, but not with what we expected. Two things
                // look like this: our picture of the text is stale, or the app
                // counts ranges differently than we do — Electron and web views
                // are prone to the second.
                //
                // We cannot tell which from here, so we do neither: skip this
                // word, and stop trusting the accessibility route in this app.
                // The next word goes through synthetic typing, which does not
                // depend on the app agreeing with us about positions. One word
                // is lost per app, once, and then it works.
                accessibilityFailures[bundleID] = Date()
                return Outcome(strategy: .accessibility, succeeded: false)
            case .tooLongForField:
                // Not the application's fault and not a reason to stop trusting
                // it: we asked to replace more text than exists. Say so, so the
                // caller can ask for less — losing the whole correction because
                // the carried neighbours did not fit is how a good decision
                // turned into nothing happening at all.
                return Outcome(strategy: .accessibility, succeeded: false,
                               runDidNotFit: true, availableBeforeCaret: lastAvailable)
            case .notSupported:
                accessibilityFailures[bundleID] = Date()
            }
        }

        guard let synthetic else { return Outcome(strategy: .synthetic, succeeded: false) }
        if awaitRendered((original as NSString).length) == .tooShort {
            return Outcome(strategy: .synthetic, succeeded: false,
                           runDidNotFit: true, availableBeforeCaret: lastAvailable)
        }
        // The last moment at which nothing has been destroyed yet.
        guard waitForAPause(inRunOf: original.count, stillValid: stillValid,
                            silence: silence, interval: interval) else {
            log("поздно: печатают")
            lateAbandons += 1
            return Outcome(strategy: .synthetic, succeeded: false, abandonedLate: true)
        }
        // Count characters, not UTF-16 units: one backspace removes one glyph,
        // and counting units would over-delete anything outside the BMP.
        log("synth \(original.count)→\(replacement.count)")
        synthetic.replace(deleting: original.count, with: replacement)
        return Outcome(strategy: .synthetic, succeeded: true)
    }

    /// Waits until the person has stopped typing for at least as long as our
    /// own burst will take, and says whether it is safe to start.
    ///
    /// A replacement is not one action. It is a lead-in, then a backspace every
    /// few milliseconds, then the new text — tens of milliseconds during which
    /// nothing can be checked, because the events are already on their way. A
    /// keystroke landing inside that run is deleted by our own backspaces, and
    /// one of the characters we meant to delete survives instead: «rfr ltkf»
    /// typed at thirty milliseconds a key came back as «rкак ела».
    ///
    /// So the question asked here is not "has anything changed" — that is the
    /// generation check — but "has this person paused long enough that they are
    /// unlikely to type into the middle of what we are about to do". Somebody
    /// typing steadily faster than our own burst gets no automatic corrections
    /// and no damage; the hotkey still works, and a miss costs half a second
    /// (CLAUDE.md §1).
    ///
    /// Waiting costs the correction a few tens of milliseconds of delay, which
    /// is below the threshold of noticing — the measured path from the space to
    /// this point is about 31 ms, so a pause of 40–100 ms lands well inside the
    /// moment a person spends before their next word.
    private func waitForAPause(inRunOf characters: Int, stillValid: () -> Bool,
                               silence: () -> Double, interval: () -> Double) -> Bool {
        let burst = burstSeconds(characters) + 0.015
        // Clamped, because these come from callers: an unknown rhythm must not
        // turn into a wait nobody can satisfy.
        let rhythm = interval()
        var waited: Double = 0
        while true {
            let quiet = min(silence(), KeyTapService.longSilence)
            if Self.mayStartBurst(quiet: quiet, rhythm: rhythm, burst: burst) {
                return stillValid()
            }
            guard stillValid() else { return false }
            guard waited < Self.longestWait else { return false }
            usleep(8_000)
            waited += 0.008
        }
    }

    /// Is this a safe moment to start a run of synthetic events?
    ///
    /// Pure, so the rule can be read and tested without a keyboard:
    ///
    /// · there is room before the next keystroke is due — the person's own
    ///   rhythm says it is further away than our burst is long; or
    /// · they have clearly stopped: silent for half again their own rhythm,
    ///   and for at least as long as the burst will take.
    ///
    /// Everything here is finite on purpose. An earlier version answered
    /// "infinitely quiet" when nobody had typed yet, and `rhythm * 1.5`
    /// overflowed to infinity — so the first comparison was never true, and the
    /// undo, which asks this question with no typing behind it, stopped working
    /// altogether.
    static func mayStartBurst(quiet: Double, rhythm: Double, burst: Double) -> Bool {
        guard burst.isFinite else { return true }
        // Clamped here rather than trusted from the caller: "nobody has typed"
        // used to arrive as infinity, and `rhythm * 1.5` overflowed.
        let quiet = quiet.isNaN ? KeyTapService.longSilence : min(quiet, KeyTapService.longSilence)
        let rhythm = rhythm.isNaN ? KeyTapService.slowestAssumedRhythm
                                  : min(max(rhythm, 0), KeyTapService.slowestAssumedRhythm)
        if quiet >= burst, rhythm > quiet + burst { return true }
        return quiet >= max(burst, rhythm * 1.5)
    }

    /// How long our own run of events will take, from the delays it is made of.
    private func burstSeconds(_ characters: Int) -> Double {
        guard let synthetic else { return 0 }
        let spacing = characters > 8 ? synthetic.backspaceDelay * 2 : synthetic.backspaceDelay
        let deleting = Double(characters) * Double(spacing) / 1_000_000
        let typing = Double((characters / 20) + 1) * Double(synthetic.typingDelay) / 1_000_000
        return Double(synthetic.leadInDelay) / 1_000_000 + deleting + typing
    }

    /// We do not hold a correction back for longer than this.
    private static let longestWait: Double = 0.250

    func forget(_ bundleID: String) { accessibilityFailures.removeValue(forKey: bundleID) }

    /// Whether the route that checks itself is expected to work here.
    ///
    /// Callers use this to decide how much text they are willing to rewrite at
    /// once. The synthetic route deletes by counting and cannot look at what it
    /// is deleting, so a run spanning several words there is several times the
    /// damage when our idea of the text is wrong.
    func hasVerifiedRoute(in bundleID: String) -> Bool { !isBlacklisted(bundleID) }

    /// Waits for the text we are about to delete backwards over to be on screen.
    ///
    /// The synthetic route sends a count of backspaces and trusts that many
    /// characters are there. We act on the space that ends a word, and an
    /// application that has not finished inserting that space yet leaves the
    /// caret one position short — so the count runs one past the word and takes
    /// the space before it. Typing `ghbdtn` then `руддщ` came out as
    /// «Приветhello»: the space between them was eaten and the user's own space
    /// arrived afterwards.
    ///
    /// macOS autocorrection makes this worse rather than causing it: it also
    /// fires on the space that ends a word, and rewrites text underneath us at
    /// exactly the moment we are measuring it.
    ///
    /// The caret position can be read in many applications where the text itself
    /// cannot, so this often confirms the length even where the verified route
    /// was unavailable. Where nothing can be read, a slightly longer wait is all
    /// that is left — better than measuring against text that is not there yet.
    private enum Fit { case confirmed, unknown, tooShort }

    @discardableResult
    private func awaitRendered(_ length: Int) -> Fit {
        guard length > 0, let element = focusedElement() else {
            usleep(blindSettleDelay); return .unknown
        }
        for _ in 0..<4 {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                                &raw) == .success,
                  let value = raw, CFGetTypeID(value) == AXValueGetTypeID()
            else { usleep(blindSettleDelay); return .unknown }
            var caret = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &caret) else {
                usleep(blindSettleDelay); return .unknown
            }
            if caret.location >= length { return .confirmed }
            usleep(15_000)
        }
        // Read it four times over sixty milliseconds and it never grew: there is
        // genuinely less text here than we meant to replace, and the caller can
        // ask for less rather than deleting into somebody else's words.
        return .tooShort
    }

    /// Extra wait before deleting text we could not measure. Short enough to be
    /// invisible, long enough for an application to finish drawing a space.
    private let blindSettleDelay: UInt32 = 35_000

    // MARK: - Accessibility route

    private func replaceViaAccessibility(original: String,
                                         with replacement: String) -> AccessibilityResult {
        guard let element = focusedElement() else { return .notSupported }

        // Where the caret is, so we can walk back over the word.
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &rangeValue) == .success,
              let axRange = rangeValue, CFGetTypeID(axRange) == AXValueGetTypeID()
        else { return .notSupported }

        var caret = CFRange()
        guard AXValueGetValue(axRange as! AXValue, .cfRange, &caret) else { return .notSupported }
        let originalCaret = caret

        /// Puts the caret back before giving up.
        ///
        /// Every early exit past this point has already changed the selection,
        /// and leaving it changed is not a cosmetic problem: the user sees their
        /// word highlighted and nothing else happen, and their next keystroke
        /// replaces the highlighted word instead of continuing the sentence.
        /// This was reported as "the words just get selected and that is all",
        /// and it was correct.
        func giveUp(_ result: AccessibilityResult, _ why: String) -> AccessibilityResult {
            lastAXReason = why
            var restore = originalCaret
            if let value = AXValueCreate(.cfRange, &restore) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            return result
        }

        var length = (original as NSString).length

        // Not enough text in front of the caret. Usually this is not a wrong
        // idea of the text but a slow one: we act on the space that ends a word,
        // and the application has not finished inserting it, so the caret sits
        // one character short of where it will be a moment from now.
        //
        // Worth waiting for rather than giving up on. Giving up meant the word
        // was left alone, and then the next word's chain rebuilt both of them in
        // one long run of backspaces — which is where the duplicated letter came
        // from. One short wait here removes the cause instead of the symptom.
        if caret.location < length {
            usleep(30_000)
            var retryValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                                &retryValue) == .success,
                  let retryRange = retryValue, CFGetTypeID(retryRange) == AXValueGetTypeID(),
                  AXValueGetValue(retryRange as! AXValue, .cfRange, &caret),
                  caret.location >= length
            else {
                lastAXReason = "каретка на \(caret.location), нужно \(length)"
                lastAvailable = caret.location
                return .tooLongForField
            }
        }
        _ = length
        length = (original as NSString).length

        // Select exactly the word, then write over the selection.
        //
        // Never kAXValueAttribute: rewriting the whole field destroys the app's
        // undo history, throws the caret back to the start, and bypasses any
        // validation the field does.
        var wordRange = CFRange(location: caret.location - length, length: length)
        guard let selection = AXValueCreate(.cfRange, &wordRange) else { return .notSupported }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                           selection) == .success
        else { return giveUp(.notSupported, "нет поддержки") }

        // Verify we actually selected what we meant to. Without this a stale
        // caret position silently overwrites the wrong characters.
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &selectedValue) == .success,
              let selected = selectedValue as? String
        else { return giveUp(.notSupported, "нет поддержки") }
        // Case alone is not a disagreement.
        //
        // macOS capitalises the first word of a sentence after we have written
        // it, so the chain remembers «привет» while the screen holds «Привет».
        // The check exists to be sure we are about to delete the characters we
        // think we are; a capital letter is the same character in the same
        // place and the same count. Treating it as a mismatch cost a word every
        // time — and, worse, put the application on the slow route for a minute,
        // which is what quietly switched off carrying short neighbours along.
        if selected.lowercased() != original.lowercased() {
            // Already done, by us, a moment ago.
            //
            // The retry above runs the whole routine a second time, and an
            // application that wrote the replacement but answered slowly the
            // first time round shows the *converted* text here. Reporting that
            // as a failure was wrong in a way nobody could see: the correction
            // was on screen and correct, while the application below concluded
            // it had failed — so it did not switch the layout, did not arm the
            // undo, and did not mark the word as converted, leaving the next
            // word to reach back over text that was no longer what it thought.
            //
            // From the outside: the word gets fixed, the keyboard stays in the
            // wrong layout, and the correction after it goes wrong. Which is
            // what "it works every other time" looked like.
            guard selected.lowercased() == replacement.lowercased() else {
                return giveUp(.mismatch,
                              "выделилось не то: \(selected.count) симв. вместо \(original.count)")
            }
            alreadyDone += 1
            lastAXReason = "уже заменено"
            var restore = originalCaret
            restore.location = originalCaret.location
            if let value = AXValueCreate(.cfRange, &restore) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            return .replaced
        }

        // The last point at which nothing has been written yet. A failure here
        // is genuinely "this app does not support it", and falling through to
        // synthetic typing is correct.
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                           replacement as CFTypeRef) == .success
        else { return giveUp(.notSupported, "нет поддержки") }

        // Past this line the text has been written. Whatever happens next, the
        // one thing we must not report is `.notSupported` — that sends the
        // caller on to the synthetic route, which deletes and types **again**.
        //
        // That is where the duplicated word came from: two replacements of seven
        // characters on a field of fourteen produced twenty-one. The read-back
        // below failed, we called it "not supported", and the fallback typed the
        // word a second time on top of the one already there.
        //
        // "Success" from AX means the message was accepted, not that anything
        // changed — browsers in particular accept and ignore — so the read-back
        // stays. Only its failure verdict changes: `.mismatch`, which stops
        // everything, rather than `.notSupported`, which starts something else.
        var afterValue: CFTypeRef?
        var afterRange = CFRange(location: wordRange.location, length: (replacement as NSString).length)
        guard let afterSelection = AXValueCreate(.cfRange, &afterRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                           afterSelection) == .success,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &afterValue) == .success,
              let after = afterValue as? String
        else { return giveUp(.mismatch, "не прочиталось после записи") }

        // Read back what we asked for: the write worked, the app simply has not
        // told us so in a way we can confirm. Treat it as done rather than doing
        // it twice.
        guard after == replacement else { return giveUp(.mismatch, "после записи не то: \(after.count) вместо \(replacement.count)") }

        // Collapse the selection so the caret sits after the word, as if typed.
        var collapsed = CFRange(location: afterRange.location + afterRange.length, length: 0)
        if let value = AXValueCreate(.cfRange, &collapsed) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
        return .replaced
    }

    /// The process to write into. Kept in step with the focus monitor so that
    /// the decision and the write cannot land in different applications.
    var targetPID: pid_t = 0

    private func focusedElement() -> AXUIElement? {
        let resolved = targetPID != 0 ? targetPID : AppMonitor.trueFrontmost()?.processIdentifier
        guard let pid = resolved else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused
        else { return nil }
        let target = element as! AXUIElement
        AXUIElementSetMessagingTimeout(target, 0.2)
        return target
    }
}
