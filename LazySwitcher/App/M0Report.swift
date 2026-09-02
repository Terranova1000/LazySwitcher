import AppKit

// ВЕСЬ ЭТОТ ФАЙЛ — ТОЛЬКО ДЛЯ ОТЛАДКИ.
//
// Леса вокруг разработки: они запускаются по появлению файла-триггера в
// ~/Library/Application Support/Lazy Switcher/, а часть из них умеет
// синтезировать нажатия клавиш. В приложении с доступом Accessibility это
// означает, что любой, кто способен записать файл в домашнюю папку, может
// заставить программу печатать. Для отладки — необходимый инструмент, в
// готовом продукте — вектор атаки, которого не должно существовать.
//
// Поэтому весь файл вырезается из Release на этапе компиляции: не «выключен
// флагом», не «спрятан за настройкой», а физически отсутствует в бинарнике.
#if DEBUG

/// M0-only scaffolding: mirrors the diagnostics window to a file so the findings
/// can be read back without a human describing the screen. Deleted at M1.
///
/// The one rule that matters here: this writes **aggregates only**. Counters,
/// permission booleans, signature facts, lengths and verdicts. No key codes, no
/// flags, no characters, nothing from which a word could be reconstructed.
///
/// CLAUDE.md rule 1 has no debug exception, and this is exactly where it gets
/// broken by accident — it did, once. The notes this file prints used to
/// interpolate the word itself, so the report became a rolling record of what
/// was being typed, while the line at the bottom of it claimed otherwise. A
/// comment asserting compliance is worse than no comment: it stops the next
/// person from checking. The notes now carry lengths and verdicts only, and the
/// claim below is true again.
enum M0Report {

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lazy Switcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("m0-report.txt")
    }

    static func write(tap: KeyTapService, secureInput: SecureInputMonitor) {
        let p = Permissions.current(runProbe: false)
        let bundle = Bundle.main
        let f = ISO8601DateFormatter()

        var lines: [String] = []
        func row(_ k: String, _ v: String) {
            lines.append(k.padding(toLength: 34, withPad: " ", startingAt: 0) + v)
        }
        func flag(_ b: Bool) -> String { b ? "да" : "нет" }

        lines.append("# Lazy Switcher — отчёт M0")
        lines.append("снят: \(f.string(from: Date()))")
        lines.append("")
        lines.append("## сборка")
        row("bundle ID", bundle.bundleIdentifier ?? "—")
        row("путь", bundle.bundlePath)
        row("в /Applications", flag(bundle.bundlePath.hasPrefix("/Applications")))
        row("App Translocation", flag(bundle.bundlePath.contains("/AppTranslocation/")))
        row("uptime, с", String(format: "%.0f", ProcessInfo.processInfo.systemUptime))
        row("память, МБ", String(format: "%.1f", residentMegabytes()))

        lines.append("")
        lines.append("## разрешения")
        row("CGPreflightListenEventAccess", flag(p.canListen))
        row("CGPreflightPostEventAccess", flag(p.canPost))
        row("AXIsProcessTrusted (не решает)", flag(p.axTrusted))
        row("готовы к работе", flag(p.isUsable))
        row("похоже на «залипшее»", flag(p.looksStuck))

        lines.append("")
        lines.append("## event tap")
        row("запущен", flag(tap.isRunning))
        row("keyDown всего", "\(tap.keyDownCount.value)")
        row("flagsChanged всего", "\(tap.flagsChangedCount.value)")
        row("отключений по таймауту", "\(tap.timeoutDisableCount.value)")
        row("отключений по вводу", "\(tap.userInputDisableCount.value)")
        row("оживлений сторожем", "\(tap.watchdogRevivalCount.value)")

        lines.append("")
        lines.append("## раскладки и слова")
        row("включённых раскладок", "\(InputSourceService.enabledKeyboardLayouts().count)")
        if let current = InputSourceService.currentLayout() {
            row("текущая", InputSourceService.localizedName(of: current) ?? "—")
        }
        if let delegate = NSApp.delegate as? AppDelegate {
            row("слов набрано", "\(delegate.wordsCommitted.value)")
            row("из них читаемы в обеих", "\(delegate.wordsConvertible.value)")
            row("запрещено к замене", "\(delegate.wordsVetoed.value)")
            row("замен сделано", "\(delegate.replacementsMade.value)")
            row("откатов", "\(delegate.undosMade.value)")
            row("последнее действие", delegate.lastReplacementNote)
            row("автозамен", "\(delegate.automaticReplacements.value)")
            row("своих событий отброшено", "\(delegate.tap.ownEventsDiscarded.value)")
            row("снимок раскладок", flag(delegate.hasLayoutPair))
            row("слов не прочитано", "\(delegate.unreadableWords.value)")
            row("история замен", delegate.replacer.history.joined(separator: " | "))
            row("спасено цепочкой", "\(delegate.chainRescues.value)")
            row("последнее решение", delegate.lastDecisionNote)
            row("модели загружены", delegate.modelStore.loadedLanguages.joined(separator: ", "))
            row("раскладка переключена", "\(delegate.inputSources.performedSwitches.value)")
            row("отказов переключить", "\(delegate.inputSources.refusedSwitches.value)")
            row("ошибок переключения", "\(delegate.inputSources.failedSwitches.value)")
            let ctx = delegate.context.current
            row("приложение", delegate.context.currentCold.appName)
            row("смен приложения поймано", "\(delegate.apps.activationsSeen)")
            row("политика", "\(ctx.policy)")
            row("поле в фокусе", "\(ctx.fieldRole)")
            row("AX role / subrole", "\(delegate.focus.lastRole) / \(delegate.focus.lastSubrole)")
            row("AX ошибка", delegate.focus.lastError)
            row("побудок дерева", "\(delegate.focus.wakeSuccesses) удачных из \(delegate.focus.wakeAttempts)")
            row("AXManualAccessibility", delegate.focus.manualAccessibilityResult)
            row("запрос окон (побудка)", delegate.focus.nudgeResult)
            row("строка меню", delegate.menuBarController.visualState)
            row("тик сторожа tap'а", "\(tap.watchdogTick.value)")
            row("оживлений tap'а", "\(tap.watchdogRevivalCount.value)")
            row("пересозданий tap'а", "\(tap.tapRebuildCount.value)")
            row("спуск внутрь", delegate.focus.descentTrace)
            row("сборок после пробуждения", "\(delegate.wakeRecoveries)")
            row("пересозданий наблюдателя", "\(delegate.focus.reobserveCount)")
            row("наблюдатель установлен", delegate.focus.hasObserver ? "да" : "нет")
            row("слепых захватов отклонено", "\(delegate.blindCarriesRefused.value)")
            row("на паузе", delegate.isPaused ? "ДА — жест ничего не сделает" : "нет")
            row("окно «что нового»", delegate.whatsNewIsOpen ? "открыто" : "закрыто")
            row("версия, показанная ранее", Settings.shared.lastSeenVersion ?? "—")
            row("ответил веб-контейнером", delegate.focus.answeredWithWebContainer ? "да" : "нет")
            row("жест разрешён", ctx.fieldRoleUnavailable ? "да (поле неопознаваемо)" : "по роли поля")
            row("замена разрешена", flag(ctx.allowsAutomaticReplacement))
        }

        lines.append("")
        lines.append("## что видели в приложениях (последние наблюдения)")
        if let delegate = NSApp.delegate as? AppDelegate {
            // Swift padding, not String(format:%-18s): the C path takes a UTF-8
            // pointer and pads by bytes, so a two-byte dash comes out as mojibake.
            for entry in delegate.focus.history.suffix(20) {
                let app = entry.app.padding(toLength: 18, withPad: " ", startingAt: 0)
                let role = entry.role.padding(toLength: 16, withPad: " ", startingAt: 0)
                let sub = entry.subrole.padding(toLength: 20, withPad: " ", startingAt: 0)
                lines.append("  \(app) \(role) \(sub) → \(entry.verdict)")
            }
        }

        lines.append("")
        lines.append("## secure input")
        row("включён сейчас", flag(secureInput.isEnabled))
        row("keyDown при Secure Input", "\(tap.keyDownDuringSecureInput.value)  (обязан быть 0)")
        row("flagsChanged при Secure Input", "\(tap.flagsChangedDuringSecureInput.value)  (ожидаем рост)")

        lines.append("")
        lines.append("(набранный текст, коды клавиш и флаги в этот файл не попадают — намеренно)")
        lines.append("")

        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }
}
#endif
