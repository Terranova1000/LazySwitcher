import AppKit
import Carbon.HIToolbox

/// Enumerating, reading and switching keyboard layouts.
final class InputSourceService {

    /// When the user last switched layouts by hand. We stay out of their way for
    /// a couple of seconds afterwards, or we end up in a switching war with them
    /// and with apps that manage the input source themselves.
    private(set) var lastManualSwitch: Date = .distantPast
    private var lastOwnSwitch: Date = .distantPast
    private var suppressNextChangeNotification = false

    var onLayoutChanged: (() -> Void)?

    // MARK: - Reading

    /// Every enabled keyboard layout.
    ///
    /// `includeAllInstalled: false` on purpose — passing true pulls in every
    /// layout on the system and noticeably grows memory. Note also that
    /// `kTISPropertyInputSourceIsEnableCapable` is NOT the filter for this: it
    /// means "may be enabled", not "is enabled".
    static func enabledKeyboardLayouts() -> [TISInputSource] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.filter { source in
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable),
                  CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
            else { return false }
            return true
        }
    }

    /// The layout actually in effect.
    ///
    /// Three functions claim to answer this and they differ:
    ///   TISCopyCurrentKeyboardInputSource      — what is selected, may be an input method
    ///   TISCopyCurrentKeyboardLayoutInputSource — the layout in force, including the
    ///                                             one underneath an input method  ← ours
    ///   TISCopyCurrentASCIICapableKeyboardLayoutInputSource — last ASCII-capable one
    static func currentLayout() -> TISInputSource? {
        TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    /// TISGetInputSourceProperty is a *Get* function: the result is not owned and
    /// must not be released, hence takeUnretainedValue throughout.
    static func identifier(of source: TISInputSource) -> String? {
        stringProperty(source, kTISPropertyInputSourceID)
    }

    static func localizedName(of source: TISInputSource) -> String? {
        stringProperty(source, kTISPropertyLocalizedName)
    }

    static func primaryLanguage(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let langs = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
        else { return nil }
        return langs.first
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    // MARK: - Switching

    /// Switches layouts, unless the user just did it themselves.
    @discardableResult
    func select(_ source: TISInputSource) -> Bool {
        let now = Date()
        // Two guards against a switching war: never twice in quick succession,
        // and never on top of a switch the user made moments ago.
        guard now.timeIntervalSince(lastOwnSwitch) > 0.3 else { return false }
        guard now.timeIntervalSince(lastManualSwitch) > 2.0 else { return false }

        suppressNextChangeNotification = true
        let status = TISSelectInputSource(source)
        guard status == noErr else { suppressNextChangeNotification = false; return false }
        lastOwnSwitch = now
        return true
    }

    // MARK: - Watching

    func startWatching() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<InputSourceService>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .handleLayoutChange()
            },
            kTISNotifySelectedKeyboardInputSourceChanged,
            nil,
            .deliverImmediately
        )
    }

    func stopWatching() {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func handleLayoutChange() {
        if suppressNextChangeNotification {
            suppressNextChangeNotification = false
        } else {
            lastManualSwitch = Date()
        }
        onLayoutChanged?()
    }
}
