import Foundation

/// The hard "no" list, checked before any scoring happens.
///
/// Every rule here exists because some tool shipped without it and damaged
/// somebody's text. They are ordered cheapest-and-most-critical first, and they
/// are absolute: no confidence score, no learned weight and no user setting
/// reaches past a veto.
///
/// The design bias throughout: **when unsure, refuse.** A miss costs the user
/// one keypress. A false correction in a command line, a captcha or a password
/// costs trust we do not get back.
enum VetoGate {

    enum Verdict: Equatable {
        case allowed
        case vetoed(Reason)
    }

    enum Reason: String, Equatable {
        case secureInput = "включён Secure Input"
        case appPolicy = "в этом приложении выключено"
        case fieldRole = "поле не для обычного текста"
        case tooShort = "слово короче минимума"
        case tooLong = "слово длиннее 24 символов"
        case userExclusion = "слово в списке «не менять»"
        case looksLikeAddress = "похоже на адрес, почту или IP"
        case looksLikePath = "похоже на путь к файлу"
        case hasDigits = "буквы вперемешку с цифрами"
        case identifierShape = "camelCase, snake_case или kebab-case"
        case looksLikePassword = "похоже на пароль"
        case shortAllCaps = "короткая аббревиатура"
        case notLetters = "не буквенное слово"
    }

    struct Input {
        let word: String
        let context: HotContext
        /// Minimum length for an automatic single-word replacement.
        let minimumLength: Int
        /// Words the user has told us to leave alone.
        let userExclusions: Set<String>
        /// True when the user asked explicitly. Length rules relax; safety does not.
        let isExplicitRequest: Bool

        init(word: String, context: HotContext, minimumLength: Int = 5,
             userExclusions: Set<String> = [], isExplicitRequest: Bool = false) {
            self.word = word
            self.context = context
            self.minimumLength = minimumLength
            self.userExclusions = userExclusions
            self.isExplicitRequest = isExplicitRequest
        }
    }

    static func evaluate(_ input: Input) -> Verdict {
        let word = input.word
        let context = input.context

        // 1–3. Context. Cheapest checks, harshest consequences.
        if context.isSecureInput { return .vetoed(.secureInput) }
        if context.policy == .disabled { return .vetoed(.appPolicy) }
        if context.fieldRole != .text { return .vetoed(.fieldRole) }

        if word.isEmpty { return .vetoed(.tooShort) }

        // 4. Length. Relaxed when the user asked, but never below two characters:
        //    every single-character word collides with a real word in the other
        //    language, so one on its own is never decidable.
        let length = word.count
        if input.isExplicitRequest {
            if length < 2 { return .vetoed(.tooShort) }
        } else if length < input.minimumLength {
            return .vetoed(.tooShort)
        }

        // 5. Base64, hashes, tokens.
        if length > 24 { return .vetoed(.tooLong) }

        // 6. The user's own list wins over everything below.
        if input.userExclusions.contains(word.lowercased()) { return .vetoed(.userExclusion) }

        // 7. Addresses. Immediately visible when broken, so checked early.
        if looksLikeAddress(word) { return .vetoed(.looksLikeAddress) }
        if looksLikePath(word) { return .vetoed(.looksLikePath) }

        // 8. Anything that is not purely letters and layout punctuation.
        if hasDigitsMixedWithLetters(word) { return .vetoed(.hasDigits) }
        if hasIdentifierShape(word) { return .vetoed(.identifierShape) }

        // 9. Self-drawn password fields that never turn on Secure Input.
        if looksLikePassword(word) { return .vetoed(.looksLikePassword) }

        // 10. MySQL, API, USB, ntlm. The rock Punto's reputation broke on.
        if isShortAllCaps(word) { return .vetoed(.shortAllCaps) }

        if !containsAnyLetter(word) { return .vetoed(.notLetters) }

        return .allowed
    }

    // MARK: - Shape tests

    private static func looksLikeAddress(_ word: String) -> Bool {
        let lower = word.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
            return true
        }
        if word.contains("@") { return true }                       // почта, упоминания
        if lower.contains("://") { return true }
        // IPv4 и MAC
        if word.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { return true }
        if word.range(of: #"^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$"#, options: .regularExpression) != nil { return true }
        // Домен: буквы, точка, известная зона на конце
        if word.range(of: #"^[\w-]+(\.[\w-]+)+$"#, options: .regularExpression) != nil,
           word.contains(".") { return true }
        return false
    }

    private static func looksLikePath(_ word: String) -> Bool {
        if word.contains("/") || word.contains("\\") { return true }
        if word.hasPrefix("~") { return true }
        if word.range(of: #"^[A-Za-z]:$"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func hasDigitsMixedWithLetters(_ word: String) -> Bool {
        let hasDigit = word.contains { $0.isNumber }
        return hasDigit && containsAnyLetter(word)
    }

    private static func hasIdentifierShape(_ word: String) -> Bool {
        if word.contains("_") || word.contains("$") || word.contains("#") { return true }
        if word.contains("-"), word.count > 3 { return true }
        if word.contains("(") || word.contains(")") { return true }
        // camelCase: an uppercase letter after a lowercase one.
        var previousWasLower = false
        for ch in word {
            if ch.isUppercase && previousWasLower { return true }
            previousWasLower = ch.isLowercase
        }
        return false
    }

    /// Long, mixed case, digits and symbols — the shape of a secret typed into a
    /// field that never announced itself as one.
    private static func looksLikePassword(_ word: String) -> Bool {
        guard word.count > 12 else { return false }
        let hasUpper = word.contains { $0.isUppercase }
        let hasLower = word.contains { $0.isLowercase }
        let hasDigit = word.contains { $0.isNumber }
        let hasSymbol = word.contains { !$0.isLetter && !$0.isNumber }
        let classes = [hasUpper, hasLower, hasDigit, hasSymbol].filter { $0 }.count
        return classes >= 3
    }

    private static func isShortAllCaps(_ word: String) -> Bool {
        guard word.count <= 4 else { return false }
        guard word.contains(where: { $0.isLetter }) else { return false }
        return !word.contains { $0.isLowercase }
    }

    private static func containsAnyLetter(_ word: String) -> Bool {
        word.contains { $0.isLetter }
    }
}
