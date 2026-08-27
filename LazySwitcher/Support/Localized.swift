import Foundation

/// Shorthand for a localized string.
///
/// Keys are stable identifiers, not English text. That costs a lookup when
/// reading the code, and buys two things: the Russian wording can be edited
/// without touching every call site, and a missing translation shows up as an
/// obvious `settings.sound.title` rather than as silent English in a Russian
/// interface.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Same, with formatting. The format string lives in the .strings file, so a
/// language that needs its arguments in a different order can reorder them with
/// positional specifiers.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}
