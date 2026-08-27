import Foundation

/// What kind of field the caret is sitting in.
enum FieldRole: UInt8 {
    /// Ordinary text we may correct.
    case text = 0
    /// A password field. Never touched.
    case secure = 1
    /// A code editor or anything where our idea of a word is wrong.
    case code = 2
    /// A terminal. The worst place to be wrong.
    case terminal = 3
    /// We could not tell. Treated as forbidden — silence is always allowed.
    case unknown = 4
}

/// How much freedom we have in the frontmost app.
enum AppPolicy: UInt8 {
    /// Never act here, not even on a hotkey.
    case disabled = 0
    /// Only when the user explicitly asks.
    case hotkeyOnly = 1
    /// Correct automatically.
    case automatic = 2
}

/// The part of the world the key thread needs, packed into one 64-bit word.
///
/// This is not premature cleverness. The key thread reads context on every
/// keystroke and must not take a lock the main thread could be holding
/// (CLAUDE.md rule 7); a struct containing a `String` cannot be read atomically
/// at all. So the hot fields are packed into a single naturally-aligned word,
/// published with one store and read with one load. Names and bundle IDs live
/// in `ColdContext`, which only the decide queue ever touches.
struct HotContext: Equatable {
    var isSecureInput: Bool = false
    var policy: AppPolicy = .disabled
    var fieldRole: FieldRole = .unknown
    var sourceLayoutSlot: UInt8 = 0
    var targetLayoutSlot: UInt8 = 0
    var generation: UInt32 = 0

    /// The app never exposes field roles at all — Chrome and Firefox, whose web
    /// accessibility tree stays unbuilt (00-DECISIONS.md, Н10).
    ///
    /// This is a different thing from "we happened to get `unknown` this time",
    /// and the distinction matters: a transient unknown may resolve on the next
    /// query, while this one never will. Only an explicit request from the user
    /// gets past it, and only because asking for a conversion is itself proof
    /// that the field is not a password.
    var fieldRoleUnavailable: Bool = false

    /// Nothing may happen unless every one of these says so. Fail closed.
    var allowsAnyAction: Bool {
        !isSecureInput && policy != .disabled && fieldRole == .text
    }

    /// The narrow exception, for a hotkey the user pressed deliberately.
    var allowsExplicitActionDespiteUnknownField: Bool {
        !isSecureInput && policy != .disabled && fieldRole == .unknown && fieldRoleUnavailable
    }

    var allowsAutomaticReplacement: Bool {
        allowsAnyAction && policy == .automatic
    }

    // MARK: - Packing

    var packed: UInt64 {
        var value: UInt64 = 0
        value |= isSecureInput ? 1 : 0
        value |= UInt64(policy.rawValue) << 1        // 2 бита
        value |= UInt64(fieldRole.rawValue) << 3     // 3 бита
        value |= (fieldRoleUnavailable ? 1 : 0) << 6
        value |= UInt64(sourceLayoutSlot) << 8
        value |= UInt64(targetLayoutSlot) << 16
        value |= UInt64(generation) << 32
        return value
    }

    init() {}

    init(packed: UInt64) {
        isSecureInput = packed & 1 != 0
        policy = AppPolicy(rawValue: UInt8((packed >> 1) & 0b11)) ?? .disabled
        fieldRole = FieldRole(rawValue: UInt8((packed >> 3) & 0b111)) ?? .unknown
        fieldRoleUnavailable = (packed >> 6) & 1 != 0
        sourceLayoutSlot = UInt8((packed >> 8) & 0xFF)
        targetLayoutSlot = UInt8((packed >> 16) & 0xFF)
        generation = UInt32((packed >> 32) & 0xFFFF_FFFF)
    }

    init(isSecureInput: Bool, policy: AppPolicy, fieldRole: FieldRole,
         fieldRoleUnavailable: Bool = false,
         sourceLayoutSlot: UInt8 = 0, targetLayoutSlot: UInt8 = 0, generation: UInt32 = 0) {
        self.isSecureInput = isSecureInput
        self.policy = policy
        self.fieldRole = fieldRole
        self.fieldRoleUnavailable = fieldRoleUnavailable
        self.sourceLayoutSlot = sourceLayoutSlot
        self.targetLayoutSlot = targetLayoutSlot
        self.generation = generation
    }
}

/// Everything else about the current context. Read on the decide queue only.
struct ColdContext {
    var bundleID: String = ""
    var appName: String = ""
    var generation: UInt32 = 0
}

/// Publishes the two halves and keeps their generations in step.
final class ContextStore {

    private let hot = AtomicCounter()
    private var cold = ColdContext()
    private var lock = os_unfair_lock_s()
    private var generation: UInt32 = 0

    /// One atomic load. Safe from the key thread.
    var current: HotContext { HotContext(packed: hot.value) }

    /// Blocks briefly; never call from the key thread.
    var currentCold: ColdContext {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return cold
    }

    /// Publishes cold first, then hot. A reader that sees the new generation in
    /// the hot word is therefore guaranteed the cold half is already there.
    func publish(hot newHot: HotContext, cold newCold: ColdContext) {
        generation &+= 1
        var h = newHot
        h.generation = generation
        var c = newCold
        c.generation = generation

        os_unfair_lock_lock(&lock)
        cold = c
        os_unfair_lock_unlock(&lock)

        hot.value = h.packed
    }

    /// Updates just the Secure Input bit, which changes far more often than the
    /// rest and must take effect immediately.
    func setSecureInput(_ active: Bool) {
        var h = HotContext(packed: hot.value)
        guard h.isSecureInput != active else { return }
        h.isSecureInput = active
        hot.value = h.packed
    }
}
