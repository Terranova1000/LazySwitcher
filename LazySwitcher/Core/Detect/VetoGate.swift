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

    /// Why a word was refused.
    ///
    /// `rawValue` is a stable identifier, deliberately not the sentence shown to
    /// the user. It was the sentence once, and that made the Russian wording
    /// load-bearing: it was simultaneously a value compared in tests, a key in
    /// logs and a line of interface text, so translating the interface would
    /// have silently broken the other two.
    enum Reason: String, Equatable, CaseIterable {
        case secureInput
        case appPolicy
        case fieldRole
        case tooShort
        case tooLong
        case userExclusion
        case looksLikeAddress
        case looksLikePath
        case hasDigits
        case identifierShape
        case looksLikePassword
        case shortAllCaps
        case notLetters

        var localizedDescription: String { L("veto.\(rawValue)") }
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
            // Порядок параметров держим стабильным: вызовов много, и путаница
            // между minimumLength и userExclusions компилируется молча.
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
        if context.fieldRole != .text {
            // One exception, and it is narrow on purpose: an explicit request in
            // an app that never exposes field roles at all (Chrome, Firefox).
            // The user pressing the hotkey is the signal we cannot obtain any
            // other way — nobody asks to convert their own password. Automatic
            // replacement stays impossible there, because those apps carry the
            // `.hotkeyOnly` policy.
            guard input.isExplicitRequest, context.allowsExplicitActionDespiteUnknownField else {
                return .vetoed(.fieldRole)
            }
        }

        if word.isEmpty { return .vetoed(.tooShort) }

        let length = word.count

        // Base64, hashes, tokens.
        if length > 24 { return .vetoed(.tooLong) }

        // Note the order: the shape rules below run **before** the minimum
        // length check, not after.
        //
        // It used to be the other way round, and that was a hole. A word too
        // short to convert on its own is not thereby safe — the chain can still
        // carry it along on a neighbour's confidence — so returning `.tooShort`
        // early meant `«ip»`, `«a1»` or `«C:»` never met the rules that exist to
        // stop exactly that. Length is about whether we may act alone; shape is
        // about whether the word may be touched at all, and that question has to
        // be answered first.

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

        // Length last. Relaxed when the user asked, but never below two
        // characters: every single-character word collides with a real word in
        // the other language, so one on its own is never decidable.
        if input.isExplicitRequest {
            if length < 2 { return .vetoed(.tooShort) }
        } else if length < input.minimumLength {
            return .vetoed(.tooShort)
        }

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
        // A single hyphen is not kebab-case, it is Russian.
        //
        // «почему-то», «какие-нибудь», «из-за», «по-моему», «кто-то» — the
        // hyphen is ordinary punctuation inside an ordinary word, and the old
        // rule («any hyphen in a word longer than three characters») refused
        // every one of them. Two or more hyphens still reads as an identifier,
        // and so does a hyphen next to a digit.
        let hyphens = word.filter { $0 == "-" }.count
        if hyphens > 1 { return true }
        if hyphens == 1 {
            if word.hasPrefix("-") || word.hasSuffix("-") { return true }
            if word.contains(where: \.isNumber) { return true }
        }
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
