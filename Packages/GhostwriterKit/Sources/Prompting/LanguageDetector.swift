import Foundation
import NaturalLanguage
import Synchronization

public enum LanguageDetector {
    static let minimumLetters = 20
    static let minimumConfidence = 0.5
    static let sampleLength = 400
    static let blockBytes = 64
    private static let englishLocale = Locale(identifier: "en_US")
    private static let lastDetection = Mutex<(sample: String, language: String?)?>(nil)

    public static func dominantLanguage(of text: String) -> String? {
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if letters >= minimumLetters { break }
        }
        guard letters >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined, confidence >= minimumConfidence
        else { return nil }
        return language.rawValue
    }

    public static func englishName(of code: String) -> String? {
        englishLocale.localizedString(forLanguageCode: code)
    }

    /// Language of the text before the caret. Detection costs about a millisecond, so it runs on a
    /// sample that only moves when the text crosses a `blockBytes` boundary, and the last result is reused.
    static func language(ofTextBefore text: String) -> String? {
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
