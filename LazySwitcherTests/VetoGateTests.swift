import XCTest
@testable import Lazy_Switcher

/// The table this project is judged by.
///
/// Every "must not touch" case here comes from a real complaint about a real
/// tool. If one of these ever flips to `.allowed`, the product is broken in the
/// way that loses users, however good the statistics look.
final class VetoGateTests: XCTestCase {

    private func ordinaryContext(policy: AppPolicy = .automatic,
                                 role: FieldRole = .text,
                                 secure: Bool = false) -> HotContext {
        HotContext(isSecureInput: secure, policy: policy, fieldRole: role)
    }

    private func verdict(_ word: String,
                         context: HotContext? = nil,
                         explicit: Bool = false,
                         exclusions: Set<String> = []) -> VetoGate.Verdict {
        VetoGate.evaluate(.init(word: word,
                                context: context ?? ordinaryContext(),
                                userExclusions: exclusions,
                                isExplicitRequest: explicit))
    }

    /// The property that matters: refused. Which rule caught it is an
    /// implementation detail, and pinning it makes the suite brittle without
    /// making the product any safer — several rules legitimately overlap.
    private func assertRefused(_ word: String, explicit: Bool = false,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(verdict(word, explicit: explicit), .allowed,
                          "«\(word)» обязано быть запрещено", file: file, line: line)
    }

    /// Use only where the specific rule is the point of the test.
    private func assertVetoed(_ word: String, _ reason: VetoGate.Reason,
                              explicit: Bool = false,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(verdict(word, explicit: explicit), .vetoed(reason),
                       "«\(word)» обязано быть запрещено: \(reason.rawValue)",
                       file: file, line: line)
    }

    private func assertAllowed(_ word: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(verdict(word), .allowed,
                       "«\(word)» должно проходить", file: file, line: line)
    }

    // MARK: - Context beats everything

    func testSecureInputVetoesEverything() {
        XCTAssertEqual(verdict("ghbdtn", context: ordinaryContext(secure: true)),
                       .vetoed(.secureInput))
        // Даже когда пользователь попросил явно
        XCTAssertEqual(verdict("ghbdtn", context: ordinaryContext(secure: true), explicit: true),
                       .vetoed(.secureInput))
    }

    func testDisabledAppVetoes() {
        XCTAssertEqual(verdict("ghbdtn", context: ordinaryContext(policy: .disabled)),
                       .vetoed(.appPolicy))
    }

    func testNonTextFieldsVeto() {
        for role: FieldRole in [.secure, .code, .terminal, .unknown] {
            XCTAssertEqual(verdict("ghbdtn", context: ordinaryContext(role: role)),
                           .vetoed(.fieldRole),
                           "Роль \(role) не должна пропускать замену")
        }
    }

    /// Fail closed: an unrecognised field is refused, not guessed at.
    func testUnknownFieldIsRefusedRatherThanGuessed() {
        XCTAssertEqual(verdict("ghbdtn", context: ordinaryContext(role: .unknown)),
                       .vetoed(.fieldRole))
    }

    // MARK: - The cases that burned Punto

    /// Автоматически их спасает уже длина, но по хоткею длина ослабляется —
    /// и вот там срабатывает правило про аббревиатуры. Проверяем оба пути,
    /// потому что опасен именно второй.
    func testAcronymsAreNeverTouched() {
        for word in ["API", "USB", "IBM", "SQL", "CSS"] {
            assertRefused(word)
            assertVetoed(word, .shortAllCaps, explicit: true)
        }
    }

    func testLongerAllCapsIsNotBlanketRefused() {
        // «HELLO» — это может быть настоящий крик, а не аббревиатура.
        // Правило про ALL CAPS сознательно ограничено четырьмя символами.
        XCTAssertEqual(verdict("HTTPS"), .allowed)
    }

    func testMixedCaseProductNamesAreNeverTouched() {
        for word in ["MySQL", "iPhone", "JavaScript", "GitHub", "macOS"] {
            assertVetoed(word, .identifierShape, explicit: true)
        }
    }

    func testCodeIdentifiersSurvive() {
        assertVetoed("snake_case", .identifierShape)
        assertVetoed("camelCase", .identifierShape, explicit: true)
        assertVetoed("kebab-case-name", .identifierShape)
        assertVetoed("$variable", .identifierShape)
    }

    func testAddressesAreNeverTouched() {
        assertVetoed("user@mail.ru", .looksLikeAddress)
        assertVetoed("192.168.1.1", .looksLikeAddress)
        assertVetoed("www.example.com", .looksLikeAddress)
        assertVetoed("https://ya.ru", .looksLikeAddress)
        assertVetoed("example.com", .looksLikeAddress)
    }

    func testPathsAreNeverTouched() {
        assertVetoed("~/Documents", .looksLikePath)
        assertVetoed("/usr/bin", .looksLikePath)
        assertVetoed("src/main", .looksLikePath)
    }

    func testTokensAndHashesAreNeverTouched() {
        assertVetoed("abcdefghijklmnopqrstuvwxyz", .tooLong)
        assertRefused("Tr0ub4dor&3xKcd!")
    }

    /// Приложения, которые рисуют поле пароля сами и не включают Secure Input.
    ///
    /// На практике большинство паролей отсекается раньше — цифрами рядом с
    /// буквами или переходом строчная→прописная. Это правило ловит остаток, и
    /// то, что оно почти всегда лишнее, — не недостаток, а смысл слоёной защиты.
    func testPasswordShapedTokensAreRefusedEvenInAPlainField() {
        assertRefused("Xk!pQmwzRtLbEn")          // ловится как identifierShape
        assertRefused("Tr0ub4dor3xKcd")          // ловится по цифрам
        assertVetoed("ABCdefghijk!mn", .looksLikePassword)   // доходит до самого правила
    }

    func testWordsWithDigitsAreRefused() {
        assertVetoed("ghbdtn123", .hasDigits)
        assertVetoed("test2024", .hasDigits)
    }

    // MARK: - Length

    func testShortWordsAreNotAutoCorrected() {
        assertVetoed("yt", .tooShort)
        assertVetoed("ghb", .tooShort)
        assertVetoed("ghbd", .tooShort)
    }

    func testHotkeyRelaxesLengthButNeverGoesToOneCharacter() {
        XCTAssertEqual(verdict("ghb", explicit: true), .allowed)
        XCTAssertEqual(verdict("yt", explicit: true), .allowed)
        XCTAssertEqual(verdict("d", explicit: true), .vetoed(.tooShort),
                       "Односимвольное слово совпадает с настоящим словом в 100% случаев")
    }

    // MARK: - The user's own list

    func testUserExclusionsWin() {
        XCTAssertEqual(verdict("ghbdtn", exclusions: ["ghbdtn"]), .vetoed(.userExclusion))
        XCTAssertEqual(verdict("GHBDTN", exclusions: ["ghbdtn"]), .vetoed(.userExclusion),
                       "Список исключений не должен зависеть от регистра")
    }

    // MARK: - What must still get through

    func testOrdinaryWordsPass() {
        for word in ["ghbdtn", "руддщ", "ntcnjdjt", "hello", "привет"] {
            assertAllowed(word)
        }
    }

    func testCapitalisedWordAtSentenceStartPasses() {
        assertAllowed("Ghbdtn")
    }

    /// Cyrillic letters that live on punctuation keys must not read as symbols.
    func testWordsWithCyrillicPunctuationLettersPass() {
        assertAllowed("ds;bdftv")   // выживаем
        assertAllowed("j,]zcytybt") // объяснение
    }
}

/// The Chrome compromise (00-DECISIONS.md, O7).
///
/// Chrome and Firefox give us no signal at all about password fields — no AX
/// subrole, no Secure Input. Refusing outright would make the product useless
/// for anyone who lives in Chrome; acting automatically would eventually type
/// into a password field. So: never on our own, only when asked.
final class OpaqueBrowserTests: XCTestCase {

    private var chrome: HotContext {
        HotContext(isSecureInput: false, policy: .hotkeyOnly,
                   fieldRole: .unknown, fieldRoleUnavailable: true)
    }

    private func verdict(_ word: String, context: HotContext, explicit: Bool) -> VetoGate.Verdict {
        VetoGate.evaluate(.init(word: word, context: context, isExplicitRequest: explicit))
    }

    func testAutomaticReplacementIsImpossibleInChrome() {
        XCTAssertEqual(verdict("ghbdtn", context: chrome, explicit: false), .vetoed(.fieldRole))
        XCTAssertFalse(chrome.allowsAutomaticReplacement)
        XCTAssertFalse(chrome.allowsAnyAction)
    }

    func testHotkeyWorksInChrome() {
        XCTAssertEqual(verdict("ghbdtn", context: chrome, explicit: true), .allowed)
    }

    /// The exception is for apps that can *never* answer, not for a query that
    /// happened to come back empty this time — those may resolve on a retry, and
    /// treating them the same would open the hole in every app.
    func testTransientUnknownIsStillRefusedEvenOnAHotkey() {
        let transient = HotContext(isSecureInput: false, policy: .automatic,
                                   fieldRole: .unknown, fieldRoleUnavailable: false)
        XCTAssertEqual(verdict("ghbdtn", context: transient, explicit: true), .vetoed(.fieldRole))
    }

    func testSecureInputStillWinsInChrome() {
        var secure = chrome
        secure.isSecureInput = true
        XCTAssertEqual(verdict("ghbdtn", context: secure, explicit: true), .vetoed(.secureInput))
    }

    /// A field Chrome *did* identify as a password — it happens for native
    /// Chrome dialogs — must be refused even on an explicit request.
    func testAKnownSecureFieldIsNeverOpenedByTheException() {
        let knownSecure = HotContext(isSecureInput: false, policy: .hotkeyOnly,
                                     fieldRole: .secure, fieldRoleUnavailable: true)
        XCTAssertEqual(verdict("ghbdtn", context: knownSecure, explicit: true), .vetoed(.fieldRole))
    }

    func testAllTheUsualShapeRulesStillApplyInChrome() {
        XCTAssertNotEqual(verdict("user@mail.ru", context: chrome, explicit: true), .allowed)
        XCTAssertNotEqual(verdict("~/Documents", context: chrome, explicit: true), .allowed)
        XCTAssertNotEqual(verdict("MySQL", context: chrome, explicit: true), .allowed)
        XCTAssertNotEqual(verdict("ABCdefghijk!mn", context: chrome, explicit: true), .allowed)
    }
}

final class OpaqueBrowserPolicyTests: XCTestCase {

    func testBrowsersWithoutFieldRolesGetHotkeyOnly() {
        let store = AppPolicyStore()
        for id in ["com.google.Chrome", "org.mozilla.firefox", "com.brave.Browser",
                   "com.microsoft.edgemac", "company.thebrowser.Browser"] {
            XCTAssertEqual(store.policy(for: id), .hotkeyOnly, "\(id): только по хоткею")
            XCTAssertTrue(store.hidesFieldRoles(id))
        }
    }

    func testSafariIsNotAmongThem() {
        let store = AppPolicyStore()
        XCTAssertEqual(store.policy(for: "com.apple.Safari"), .automatic,
                       "В Safari поле пароля определяется, автозамена разрешена")
        XCTAssertFalse(store.hidesFieldRoles("com.apple.Safari"))
    }

    func testUserMayStillTurnChromeOffCompletely() {
        let store = AppPolicyStore()
        XCTAssertTrue(store.setPolicy(.disabled, for: "com.google.Chrome"))
        XCTAssertEqual(store.policy(for: "com.google.Chrome"), .disabled)
    }
}
