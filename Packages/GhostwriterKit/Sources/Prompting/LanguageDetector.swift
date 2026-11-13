import Foundation
import NaturalLanguage
import Synchronization

public enum LanguageDetector {
    static let minimumLetters = 10
    static let minimumConfidence = 0.5
    static let unexpectedMinimumLetters = 20
    static let unexpectedMinimumConfidence = 0.95
    static let recentLimit = 3
    static let sampleLength = 400
    static let blockBytes = 64
    private static let englishLocale = Locale(identifier: "en_US")
    private static let lastDetection = Mutex<(sample: String, language: String?)?>(nil)
    private static let recent = Mutex<[String]>([])

    /// A language the user is expected to write, one of the system's preferred languages or one detected
    /// confidently in recent text, needs less text and a lower confidence than any other language.
    /// Short text is often read as an unrelated language, such as English chat as Dutch or Indonesian.
    public static func dominantLanguage(of text: String) -> String? {
        let expected = expectedLanguages(preferred: Locale.preferredLanguages, recent: recent.withLock { $0 })
        guard let language = dominantLanguage(of: text, expected: expected) else { return nil }
        if !expected.contains(baseCode(language)) {
            recent.withLock { $0 = remembering(baseCode(language), in: $0) }
        }
        return language
    }

    static func dominantLanguage(of text: String, expected: [String]) -> String? {
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if letters >= unexpectedMinimumLetters { break }
        }
        guard letters >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined
        else { return nil }
        let isExpected = expected.contains(baseCode(language.rawValue))
        let isConfident = isExpected
            ? confidence >= minimumConfidence
            : letters >= unexpectedMinimumLetters && confidence >= unexpectedMinimumConfidence
        return isConfident ? language.rawValue : nil
    }

    static func expectedLanguages(preferred: [String], recent: [String]) -> [String] {
        var seen: Set<String> = []
        return (preferred.map(baseCode) + recent).filter { seen.insert($0).inserted }
    }

    static func remembering(_ language: String, in recent: [String]) -> [String] {
        Array(([language] + recent.filter { $0 != language }).prefix(recentLimit))
    }

    private static func baseCode(_ identifier: String) -> String {
        String(identifier.prefix { $0 != "-" && $0 != "_" })
    }

    public static func englishName(of code: String) -> String? {
        englishLocale.localizedString(forLanguageCode: code)
    }

    /// Language of the text before the caret. Detection costs about a millisecond, so it runs on a
    /// sample that only moves when the text crosses a `blockBytes` boundary, and the last result is reused.
    public static func language(ofTextBefore text: String) -> String? {
        let sample = stableSample(of: text)
        if let cached = lastDetection.withLock({ $0 }), cached.sample == sample { return cached.language }
        let language = dominantLanguage(of: sample)
        lastDetection.withLock { $0 = (sample, language) }
        return language
    }

    static func stableSample(of text: String) -> String {
        let utf8 = text.utf8
        let aligned = utf8.count / blockBytes * blockBytes
        guard aligned > 0, aligned < utf8.count else { return String(text.suffix(sampleLength)) }
        var end = utf8.index(utf8.startIndex, offsetBy: aligned)
        while end > utf8.startIndex, UTF8.isContinuation(utf8[end]) {
            end = utf8.index(before: end)
        }
        return String(text[..<end].suffix(sampleLength))
    }
}
