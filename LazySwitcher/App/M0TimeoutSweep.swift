import AppKit
import CoreGraphics

/// Finds the point at which macOS decides our tap callback is too slow.
///
/// Apple documents that `.tapDisabledByTimeout` exists but never says what the
/// budget is, and every number quoted online is folklore. The only way to know is
/// to walk into it, so this does: stall the callback for a known number of
/// milliseconds, drive it with an event we post ourselves, and see whether the
/// system pulls the plug.
///
/// It drives the callback with **F16** — a key that exists on the extended layout,
/// is unbound in essentially everything, and therefore cannot type a character or
/// trigger a shortcut in whatever happens to be focused. The events carry our own
/// marker, so they are discarded as ours immediately after the stall and never
/// reach the word buffer.
///
/// M0 scaffolding. Deleted at M1, along with the stall paths it needs.
enum M0TimeoutSweep {

    private static let flagFile = "m0-sweep"
    private static let defaultStalls: [UInt64] = [50, 100, 250, 500, 750, 1000, 1500, 2000]
    /// Overridden by whitespace-separated numbers in the trigger file, so the
    /// range can be narrowed without a rebuild.
    private static var stallsMilliseconds: [UInt64] = defaultStalls
    private static let f16KeyCode: CGKeyCode = 0x6A

    static var resultsURL: URL {
        M0Report.url.deletingLastPathComponent().appendingPathComponent("m0-timeout-sweep.txt")
    }

    private static var triggerURL: URL {
        M0Report.url.deletingLastPathComponent().appendingPathComponent(flagFile)
    }

    /// Watches for a trigger file so the sweep can be started without a human
    /// clicking a button.
    static func watchForTrigger(tap: KeyTapService) {
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            guard FileManager.default.fileExists(atPath: triggerURL.path) else { return }
            let requested = (try? String(contentsOf: triggerURL, encoding: .utf8))?
                .split(whereSeparator: \.isWhitespace).compactMap { UInt64($0) } ?? []
            stallsMilliseconds = requested.isEmpty ? defaultStalls : requested
            try? FileManager.default.removeItem(at: triggerURL)
            DispatchQueue.global(qos: .utility).async { run(tap: tap) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    static func run(tap: KeyTapService) {
        var lines = ["# Порог отключения tap'а по таймауту",
                     "# стенд: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "",
                     "задержка в колбэке   отключений   вывод"]

        guard let source = CGEventSource(stateID: .privateState) else {
            lines.append("не удалось создать CGEventSource")
            try? lines.joined(separator: "\n").write(to: resultsURL, atomically: true, encoding: .utf8)
            return
        }
        source.userData = KeyTapService.syntheticMarker
        // Without this macOS mutes the user's real keyboard for a quarter second
        // after each event we post.
        source.localEventsSuppressionInterval = 0

        var firstFailure: UInt64?

        for stall in stallsMilliseconds {
            let before = tap.timeoutDisableCount.value
            tap.sweepStallMilliseconds.value = stall

            // Three events per step: the first one that overruns gets the tap
            // disabled, and we want to see it come back for the next one.
            for _ in 0..<3 {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: f16KeyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: f16KeyCode, keyDown: false)
                else { continue }
                down.flags = []; up.flags = []
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
                usleep(useconds_t(stall * 1000) + 250_000)
            }

            tap.sweepStallMilliseconds.value = 0
            usleep(300_000)

            let fired = tap.timeoutDisableCount.value - before
            let verdict = fired > 0 ? "ОТКЛЮЧЁН системой" : "пережил"
            if fired > 0, firstFailure == nil { firstFailure = stall }
            lines.append(String(format: "%6d мс          %6d       %@", stall, fired, verdict))
        }

        lines.append("")
        if let firstFailure {
            lines.append("Первое отключение: \(firstFailure) мс.")
            lines.append("Значит бюджет колбэка лежит между \(previousStep(firstFailure)) и \(firstFailure) мс.")
        } else {
            lines.append("Ни одна задержка вплоть до \(stallsMilliseconds.last ?? 0) мс не вызвала отключения.")
        }
        lines.append("Оживлений сторожевым таймером за всё время: \(tap.watchdogRevivalCount.value)")
        lines.append("")
        try? lines.joined(separator: "\n").write(to: resultsURL, atomically: true, encoding: .utf8)
    }

    private static func previousStep(_ value: UInt64) -> UInt64 {
        guard let index = stallsMilliseconds.firstIndex(of: value), index > 0 else { return 0 }
        return stallsMilliseconds[index - 1]
    }
}
