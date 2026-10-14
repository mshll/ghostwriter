import AppKit

@MainActor
enum SpellFilter {
    static func realWords(_ candidates: [String], language: String?) -> [String] {
        let checker = NSSpellChecker.shared
        guard let language, let dictionary = checker.availableLanguages.first(where: {
            $0 == language || $0.hasPrefix(language + "_")
        }) else { return candidates }
        return candidates.filter {
            checker.checkSpelling(
                of: $0, startingAt: 0, language: dictionary, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
    }
}
