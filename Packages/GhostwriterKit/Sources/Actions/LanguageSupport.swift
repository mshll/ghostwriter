import Foundation
import FoundationModels
import NaturalLanguage

enum LanguageSupport {
    private static let english = Locale(identifier: "en")

    static func dominantLanguage(of text: String) -> String? {
        guard text.count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.6, language != .undetermined
        else { return nil }
        return language.rawValue
    }

    static func isSupported(_ code: String) -> Bool {
        SystemLanguageModel.default.supportsLocale(Locale(identifier: code))
    }

    static func displayName(_ code: String) -> String {
        english.localizedString(forIdentifier: code) ?? code
    }

    static func resolveTarget(_ target: String) -> (name: String, code: String?) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let isoCodes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))
        if let code = Locale(identifier: trimmed).language.languageCode?.identifier, isoCodes.contains(code),
           trimmed.count <= 3 || trimmed.contains("-") || trimmed.contains("_") {
            return (displayName(trimmed), trimmed)
        }
        let match = isoCodes.first {
            english.localizedString(forLanguageCode: $0)?.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        return (trimmed, match)
    }
}
