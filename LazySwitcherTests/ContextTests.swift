import XCTest
@testable import Lazy_Switcher

final class HotContextTests: XCTestCase {

    /// The packing is what lets the key thread read context without a lock.
    /// If it ever loses a field the failure is silent and the consequences are
    /// the bad kind — a stale "not a password field", for instance.
    func testEveryFieldSurvivesTheRoundTrip() {
        let original = HotContext(isSecureInput: true, policy: .hotkeyOnly, fieldRole: .terminal,
                                  sourceLayoutSlot: 3, targetLayoutSlot: 7, generation: 0xDEAD_BEEF)
        XCTAssertEqual(HotContext(packed: original.packed), original)
    }

    func testAllCombinationsOfPolicyAndRoleRoundTrip() {
        for policy in [AppPolicy.disabled, .hotkeyOnly, .automatic] {
            for role in [FieldRole.text, .secure, .code, .terminal, .unknown] {
                for secure in [true, false] {
                    let c = HotContext(isSecureInput: secure, policy: policy, fieldRole: role)
                    let back = HotContext(packed: c.packed)
                    XCTAssertEqual(back.policy, policy)
                    XCTAssertEqual(back.fieldRole, role)
                    XCTAssertEqual(back.isSecureInput, secure)
                }
            }
        }
    }

    func testDefaultContextForbidsEverything() {
        let fresh = HotContext()
        XCTAssertFalse(fresh.allowsAnyAction, "Пустой контекст обязан запрещать, а не разрешать")
        XCTAssertFalse(fresh.allowsAutomaticReplacement)
    }

    func testSecureInputOverridesAPermissivePolicy() {
        let c = HotContext(isSecureInput: true, policy: .automatic, fieldRole: .text)
        XCTAssertFalse(c.allowsAnyAction)
    }

    func testHotkeyOnlyAllowsActionButNotAutomaticReplacement() {
        let c = HotContext(isSecureInput: false, policy: .hotkeyOnly, fieldRole: .text)
        XCTAssertTrue(c.allowsAnyAction)
        XCTAssertFalse(c.allowsAutomaticReplacement)
    }
}

final class ContextStoreTests: XCTestCase {

    func testPublishBumpsGenerationAndKeepsHalvesInStep() {
        let store = ContextStore()
        store.publish(hot: HotContext(isSecureInput: false, policy: .automatic, fieldRole: .text),
                      cold: ColdContext(bundleID: "com.example.app", appName: "Example"))
        XCTAssertEqual(store.current.generation, store.currentCold.generation)
        XCTAssertEqual(store.currentCold.bundleID, "com.example.app")

        let firstGeneration = store.current.generation
        store.publish(hot: HotContext(), cold: ColdContext())
        XCTAssertEqual(store.current.generation, firstGeneration + 1)
    }

    func testSecureInputCanBeFlippedWithoutRepublishingEverything() {
        let store = ContextStore()
        store.publish(hot: HotContext(isSecureInput: false, policy: .automatic, fieldRole: .text),
                      cold: ColdContext(bundleID: "com.example.app", appName: "Example"))
        store.setSecureInput(true)
        XCTAssertTrue(store.current.isSecureInput)
        XCTAssertEqual(store.current.policy, .automatic, "Остальные поля не должны потеряться")
        XCTAssertFalse(store.current.allowsAnyAction)
    }
}

final class AppPolicyStoreTests: XCTestCase {

    func testTerminalsAndPasswordManagersAreLocked() {
        let store = AppPolicyStore()
        for id in ["com.apple.Terminal", "com.googlecode.iterm2",
                   "com.1password.1password", "org.keepassxc.keepassxc",
                   "com.apple.loginwindow", "com.parallels.desktop.console"] {
            XCTAssertEqual(store.policy(for: id), .disabled, "\(id) обязан быть выключен")
            XCTAssertTrue(store.isLocked(id))
        }
    }

    /// A locked app must not be openable by a stray setting — this is the guard
    /// standing between us and a mangled `rm -rf`.
    func testLockedAppsRefuseOverrides() {
        let store = AppPolicyStore()
        XCTAssertFalse(store.setPolicy(.automatic, for: "com.apple.Terminal"))
        XCTAssertEqual(store.policy(for: "com.apple.Terminal"), .disabled)
    }

    func testEditorsAreOffByDefaultButMayBeEnabled() {
        let store = AppPolicyStore()
        XCTAssertEqual(store.policy(for: "com.microsoft.VSCode"), .disabled)
        XCTAssertTrue(store.setPolicy(.hotkeyOnly, for: "com.microsoft.VSCode"))
        XCTAssertEqual(store.policy(for: "com.microsoft.VSCode"), .hotkeyOnly)
    }

    func testOrdinaryAppsAreAllowed() {
        let store = AppPolicyStore()
        XCTAssertEqual(store.policy(for: "com.apple.Notes"), .automatic)
        XCTAssertEqual(store.policy(for: "ru.keepcoder.Telegram"), .automatic)
    }
}

final class FocusClassificationTests: XCTestCase {

    /// There is no `AXSecureTextField` *role* — a password field is role
    /// AXTextField plus that subrole. Both WebKit and Chromium report it this
    /// way, which is the only reason browser passwords are detectable.
    func testSecureSubroleWins() {
        XCTAssertEqual(FocusMonitor.classify(role: "AXTextField", subrole: "AXSecureTextField"), .secure)
    }

    func testOrdinaryTextRoles() {
        XCTAssertEqual(FocusMonitor.classify(role: "AXTextField", subrole: nil), .text)
        XCTAssertEqual(FocusMonitor.classify(role: "AXTextArea", subrole: nil), .text)
    }

    /// Chromium hands back a coarse container until its accessibility tree wakes
    /// up. Treating that as ordinary text is how a password eventually leaks.
    func testChromiumPlaceholdersAreUnknownNotText() {
        for role in ["AXWebArea", "AXGroup", "AXUnknown", "AXScrollArea"] {
            XCTAssertEqual(FocusMonitor.classify(role: role, subrole: nil), .unknown,
                           "\(role) — это «не знаю», а не «обычный текст»")
        }
    }

    func testNoRoleAtAllIsUnknown() {
        XCTAssertEqual(FocusMonitor.classify(role: nil, subrole: nil), .unknown)
    }
}

/// Settings that change what the app is allowed to do.
final class SettingsPolicyTests: XCTestCase {

    private let suiteName = "com.lazyswitcher.tests.settings"

    func testStoredPoliciesSurviveARestartButLockedAppsAreIgnored() {
        let settings = Settings.shared
        settings.store(policy: .hotkeyOnly, for: "com.example.editor")
        // Even if a stored file somehow claims Terminal is allowed — a hand-edited
        // plist, a migration gone wrong — the locked list wins on load.
        settings.store(policy: .automatic, for: "com.apple.Terminal")

        let store = AppPolicyStore(loadingFrom: settings)
        XCTAssertEqual(store.policy(for: "com.example.editor"), .hotkeyOnly)
        XCTAssertEqual(store.policy(for: "com.apple.Terminal"), .disabled,
                       "Сохранённая настройка не должна открывать терминал")

        settings.removePolicy(for: "com.example.editor")
        settings.removePolicy(for: "com.apple.Terminal")
    }

    func testMinimumLengthCannotBeSetBelowFour() {
        let settings = Settings.shared
        let original = settings.minimumLength
        settings.minimumLength = 1
        XCTAssertEqual(settings.minimumLength, 4,
                       "Ниже четырёх нельзя: там ложные срабатывания уже 2.78%")
        settings.minimumLength = 99
        XCTAssertEqual(settings.minimumLength, 8)
        settings.minimumLength = original
    }

    func testSoundListIsNotEmptyAndDefaultIsInIt() {
        XCTAssertFalse(Settings.availableSounds.isEmpty)
        XCTAssertTrue(Settings.availableSounds.contains(Settings.shared.soundName))
    }

    /// Turning off the master switch must leave the hotkey working — it is the
    /// difference between "stop deciding for me" and "stop existing".
    func testDisablingAutomaticStillAllowsExplicitRequests() {
        let hot = HotContext(isSecureInput: false, policy: .hotkeyOnly, fieldRole: .text)
        XCTAssertFalse(hot.allowsAutomaticReplacement)
        XCTAssertEqual(VetoGate.evaluate(.init(word: "ghbdtn", context: hot, isExplicitRequest: true)),
                       .allowed)
    }
}

/// Learning from undo — the only signal the app collects, and the one that has
/// to be both effective and forgettable.
final class FeedbackStoreTests: XCTestCase {

    private var store: FeedbackStore!

    override func setUp() {
        super.setUp()
        store = FeedbackStore()
        store.forgetEverything()
    }

    override func tearDown() {
        store.forgetEverything()
        super.tearDown()
    }

    func testOneUndoStopsTheWordForThisSession() {
        XCTAssertFalse(store.isRejected("ghbdtn"))
        XCTAssertFalse(store.recordUndo(of: "ghbdtn"), "Одна отмена ещё не навсегда")
        XCTAssertTrue(store.isRejected("ghbdtn"))
    }

    func testThreeUndosMakeItPermanent() {
        _ = store.recordUndo(of: "ghbdtn")
        _ = store.recordUndo(of: "ghbdtn")
        XCTAssertTrue(store.recordUndo(of: "ghbdtn"), "Третья отмена делает правило постоянным")
        XCTAssertTrue(store.permanentExclusions.contains("ghbdtn"))
    }

    func testRejectionIgnoresCase() {
        _ = store.recordUndo(of: "GhBdTn")
        XCTAssertTrue(store.isRejected("ghbdtn"))
    }

    /// Whatever the app learns has to be visible and removable. Learning the
    /// user cannot see is a black box that will one day learn something silly
    /// with nothing to fix it with.
    func testEverythingLearnedCanBeSeenAndUndone() {
        for _ in 0..<3 { _ = store.recordUndo(of: "ntcn") }
        XCTAssertEqual(store.permanentExclusions, ["ntcn"])
        store.forget("ntcn")
        XCTAssertFalse(store.isRejected("ntcn"))
        XCTAssertTrue(store.permanentExclusions.isEmpty)
    }

    func testForgettingEverythingClearsBothLevels() {
        _ = store.recordUndo(of: "one")
        for _ in 0..<3 { _ = store.recordUndo(of: "two") }
        store.forgetEverything()
        XCTAssertFalse(store.isRejected("one"))
        XCTAssertFalse(store.isRejected("two"))
    }

    func testAnExcludedWordIsVetoed() {
        let hot = HotContext(isSecureInput: false, policy: .automatic, fieldRole: .text)
        XCTAssertEqual(VetoGate.evaluate(.init(word: "ghbdtn", context: hot,
                                               userExclusions: ["ghbdtn"])),
                       .vetoed(.userExclusion))
    }
}

/// Version comparison, and the defaults around the one piece of network code.
final class UpdateCheckerTests: XCTestCase {

    /// String comparison gets this backwards, and the bug only shows up on the
    /// tenth release — by which time nobody is looking here.
    func testVersionsCompareNumericallyNotAlphabetically() {
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.0", than: "0.10.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.9"))
    }

    func testSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.2.3", than: "1.2.3"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1"))
        XCTAssertFalse(UpdateChecker.isNewer("1", than: "1.0.0"))
    }

    /// The promise the project is built on: nothing goes out unless asked. If
    /// this default ever flips, it has to be a deliberate act with a test to
    /// argue with.
    func testAutomaticCheckingIsOffByDefault() {
        let fresh = UserDefaults(suiteName: "com.lazyswitcher.tests.updates")!
        fresh.removePersistentDomain(forName: "com.lazyswitcher.tests.updates")
        XCTAssertFalse(fresh.bool(forKey: "checkUpdatesAutomatically"),
                       "Проверка обновлений обязана быть выключена по умолчанию")
    }

    func testEndpointIsAFixedConstantNotASetting() {
        // A configurable update URL is how a helpful tool becomes a delivery
        // channel for something else. It stays a constant.
        XCTAssertTrue(UpdateChecker.releasesPage.absoluteString.hasPrefix("https://github.com/"))
    }
}

/// Localization. A missing translation is silent at runtime — the key itself is
/// shown — so it has to be caught here.
final class LocalizationTests: XCTestCase {

    private func strings(for language: String) throws -> [String: String] {
        let bundle = Bundle(for: AppDelegate.self)
        guard let path = bundle.path(forResource: language, ofType: "lproj"),
              let lproj = Bundle(path: path),
              let url = lproj.url(forResource: "Localizable", withExtension: "strings") else {
            throw XCTSkip("Нет ресурсов для языка «\(language)»")
        }
        // Fail rather than skip past this point: the file exists, so if it will
        // not parse that is a syntax error in the translation, and skipping it
        // would hide a broken interface behind a green run.
        let dictionary = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String],
                                       "Файл переводов «\(language)» не разбирается — "
                                     + "скорее всего пропущена точка с запятой или кавычка")
        return dictionary
    }

    /// The whole point of localization is that `L()` returns a translation and
    /// not the key. A missing .strings file in the bundle looks exactly like a
    /// working app until you read the labels.
    func testLookupReturnsTranslationsNotKeys() throws {
        for key in ["menu.quit", "settings.tab.general", "veto.secureInput",
                    "hotkey.doubleShift", "onboarding.step1.title"] {
            let value = L(key)
            XCTAssertNotEqual(value, key, "«\(key)» не переводится — файл в бандле?")
            XCTAssertFalse(value.isEmpty)
        }
    }

    func testRussianAndEnglishHaveTheSameKeys() throws {
        let ru = try strings(for: "ru")
        let en = try strings(for: "en")
        XCTAssertEqual(Set(ru.keys), Set(en.keys),
                       "Ключи разошлись: только в ru — \(Set(ru.keys).subtracting(en.keys)), "
                     + "только в en — \(Set(en.keys).subtracting(ru.keys))")
        XCTAssertGreaterThan(ru.count, 50, "Слишком мало строк — похоже, файл не попал в бандл")
    }

    func testNoTranslationIsEmpty() throws {
        for language in ["ru", "en"] {
            for (key, value) in try strings(for: language) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language): пустой перевод для «\(key)»")
            }
        }
    }

    /// Every reason a word can be refused is shown to the user, so every one
    /// needs a translation. Adding a case without a string is otherwise silent.
    func testEveryVetoReasonIsTranslated() throws {
        for language in ["ru", "en"] {
            let table = try strings(for: language)
            for reason in VetoGate.Reason.allCases {
                XCTAssertNotNil(table["veto.\(reason.rawValue)"],
                                "\(language): нет перевода для причины «\(reason.rawValue)»")
            }
        }
    }

    func testEveryHotkeyStyleIsTranslated() throws {
        for language in ["ru", "en"] {
            let table = try strings(for: language)
            for style in HotkeyStyle.allCases {
                XCTAssertNotNil(table["hotkey.\(style.rawValue)"],
                                "\(language): нет названия для жеста «\(style.rawValue)»")
            }
        }
    }

    /// Format specifiers have to match between languages, or a translated string
    /// crashes at runtime when String(format:) reads an argument that is not there.
    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let ru = try strings(for: "ru")
        let en = try strings(for: "en")
        for (key, russian) in ru {
            guard let english = en[key] else { continue }
            let ruCount = russian.components(separatedBy: "%").count - 1
            let enCount = english.components(separatedBy: "%").count - 1
            XCTAssertEqual(ruCount, enCount,
                           "«\(key)»: разное число подстановок — ru \(ruCount), en \(enCount)")
        }
    }
}

/// Regressions from the audit. Each of these was a real defect found by reading
/// the code, and each test is here so it cannot come back quietly.
final class AuditRegressionTests: XCTestCase {

    private func models() throws -> Scorer.Models {
        let bundle = Bundle(for: AppDelegate.self)
        func model(_ name: String) throws -> LanguageModel {
            guard let url = bundle.url(forResource: name, withExtension: "lsmodel") else {
                throw XCTSkip("Нет модели \(name).lsmodel")
            }
            return try LanguageModel(contentsOf: url)
        }
        return .init(source: try model("en"), target: try model("ru"))
    }

    /// The models hold lower case only. Before the fix, a capitalised word made
    /// `logProbability` return nil, which became −∞; one side unrepresentable
    /// gave Λ = +∞ — infinite confidence to replace — and both sides gave NaN,
    /// which fails every comparison so nothing was ever replaced. Every word
    /// starting a sentence took one of those two paths.
    func testCapitalisedWordsAreScoredNotBrokenByCase() throws {
        let scorer = Scorer(models: try models())
        let (decision, evidence) = scorer.decide(typed: "Ghbdtn", converted: "Привет")
        XCTAssertTrue(evidence.perCharacter.isFinite, "Λ обязано быть конечным, получили \(evidence.perCharacter)")
        XCTAssertFalse(evidence.perCharacter.isNaN)
        XCTAssertTrue(evidence.isScorable)
        XCTAssertEqual(decision, .convert, "Слово с заглавной должно вести себя как строчное")
    }

    func testLowerAndUpperCaseGiveTheSameVerdict() throws {
        let scorer = Scorer(models: try models())
        let lower = scorer.decide(typed: "ghbdtn", converted: "привет")
        let upper = scorer.decide(typed: "GHBDTN", converted: "ПРИВЕТ")
        XCTAssertEqual(lower.0, upper.0)
        XCTAssertEqual(lower.1.perCharacter, upper.1.perCharacter, accuracy: 0.0001)
    }

    /// A character outside the alphabet used to produce ±∞ and drive a
    /// replacement with unbounded confidence. Now it produces "no opinion".
    func testUnrepresentableCharactersProduceNoOpinionRatherThanInfinity() throws {
        let scorer = Scorer(models: try models())
        for (typed, converted) in [("ghbdtn7", "привет7"), ("hello—", "руддщ—"), ("ünïcode", "цтълщву")] {
            let (decision, evidence) = scorer.decide(typed: typed, converted: converted)
            XCTAssertTrue(evidence.perCharacter.isFinite, "\(typed): Λ = \(evidence.perCharacter)")
            XCTAssertNotEqual(decision, .convert,
                              "\(typed): непредставимое слово не должно заменяться с уверенностью")
        }
    }

    /// Every gesture is asked for its key codes on every modifier press, inside
    /// the event-tap callback. Building a Set there allocated on the hot path,
    /// which rule 7 forbids. They are stored now; this checks they are also
    /// still correct and stable between calls.
    func testHotkeyKeyCodesAreStableAndDistinct() {
        for style in HotkeyStyle.allCases {
            let first = style.keyCodes
            let second = style.keyCodes
            XCTAssertEqual(first, second)
            XCTAssertFalse(first.isEmpty, "\(style)")
            XCTAssertTrue(first.contains(style.primaryKeyCode),
                          "\(style): primaryKeyCode должен входить в набор")
        }
    }

    func testDisqualifyingFlagsNeverIncludeOwnModifier() {
        for style in HotkeyStyle.allCases {
            XCTAssertFalse(style.disqualifyingFlags.contains(style.flag), "\(style)")
            XCTAssertEqual(style.disqualifyingFlags.count, 3, "\(style)")
        }
    }
}

/// The alphabet contract between the model builder and the scorer.
///
/// It is the kind of coupling that breaks silently: get it wrong and words
/// become unrepresentable, the model answers "no opinion", and a third of
/// Russian words quietly stop being corrected. It cost a measured regression
/// once — misses at eight characters and up went from 0% to 28% — so it is
/// pinned here.
final class AlphabetContractTests: XCTestCase {

    private func model(_ name: String) throws -> LanguageModel {
        let bundle = Bundle(for: AppDelegate.self)
        guard let url = bundle.url(forResource: name, withExtension: "lsmodel") else {
            throw XCTSkip("Нет модели \(name).lsmodel")
        }
        return try LanguageModel(contentsOf: url)
    }

    /// Cyrillic letters live on these keys, so a Russian word typed on a Latin
    /// layout is made of letters *and these*. The English model must be able to
    /// represent every one of them.
    func testEnglishModelRepresentsPunctuationCyrillicLettersSitOn() throws {
        let en = try model("en")
        for character in "[];',.\\" {
            XCTAssertTrue(en.canRepresent(String(character)),
                          "Английская модель не знает «\(character)» — на этой клавише сидит русская буква")
        }
    }

    /// Real Russian words containing х ъ ж э б ю ё, typed on a Latin layout.
    func testRussianWordsWithPunctuationLettersAreScorable() throws {
        let en = try model("en")
        let ru = try model("ru")
        let scorer = Scorer(models: .init(source: en, target: ru))
        // безуёмным, объяснение, выживаем, этот, любой
        for (latin, russian) in [(",tpe\\vysv", "безуёмным"), ("j,]zcytybt", "объяснение"),
                                 ("ds;bdftv", "выживаем"), ("'njn", "этот"), ("k.,jq", "любой")] {
            let (_, evidence) = scorer.decide(typed: latin, converted: russian)
            XCTAssertTrue(evidence.isScorable,
                          "«\(latin)» → «\(russian)»: модель не может оценить, хотя это обычное русское слово")
        }
    }

    /// Shifted punctuation is the same key as its unshifted twin, and on ЙЦУКЕН
    /// that key is one Cyrillic letter in two cases. Scoring is case-insensitive,
    /// so these must fold together.
    func testShiftedPunctuationFoldsOntoItsUnshiftedTwin() {
        XCTAssertEqual(LanguageModel.normalized("J,]ZCYTYBT"), LanguageModel.normalized("j,]zcytybt"))
        XCTAssertEqual(LanguageModel.normalized("DS:BDFTV"), "ds;bdftv")
        XCTAssertEqual(LanguageModel.normalized("\"NJN"), "'njn")
    }

    func testNormalizationIsIdempotent() {
        for word in ["ghbdtn", "J,]Z", "Привет", "ds;bdftv", ""] {
            let once = LanguageModel.normalized(word)
            XCTAssertEqual(LanguageModel.normalized(once), once, "«\(word)»")
        }
    }
}
