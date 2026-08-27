import Foundation

/// Holds the language models, mapped in on first use.
///
/// Lazy on purpose: mapping is cheap but not free, and an agent that launches at
/// login should not touch three megabytes of file before the user has typed
/// anything. Once mapped the pages are file-backed and evictable, so they cost
/// nothing at rest.
final class ModelStore {

    private var models: [String: LanguageModel] = [:]
    private var failed: Set<String> = []

    /// Language codes we ship models for. Adding a language means adding a file
    /// here, not touching the engine.
    static let supported: Set<String> = ["ru", "en"]

    func model(for language: String) -> LanguageModel? {
        if let existing = models[language] { return existing }
        guard Self.supported.contains(language), !failed.contains(language) else { return nil }
        guard let url = Bundle.main.url(forResource: language, withExtension: "lsmodel"),
              let model = try? LanguageModel(contentsOf: url) else {
            // Missing or corrupt model means we simply do not act for that
            // language. Refusing to work is always allowed; guessing is not.
            failed.insert(language)
            return nil
        }
        models[language] = model
        return model
    }

    var loadedLanguages: [String] { models.keys.sorted() }
}
