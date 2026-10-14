import AppKit

public struct Misspelling: Sendable, Hashable {
    public var word: String
    /// Characters from the end of the word to the end of the checked text, counted in grapheme clusters.
    public var distanceFromEnd: Int
    /// Best first.
    public var guesses: [String]
    /// The spell checker's own autocorrection, also first in `guesses`.
    public var correction: String?

    public init(word: String, distanceFromEnd: Int, guesses: [String], correction: String? = nil) {
        self.word = word
        self.distanceFromEnd = distanceFromEnd
        self.guesses = guesses
        self.correction = correction
    }
}

@MainActor
public enum SpellCheck {
    static let maxGuesses = 4
    static let sentenceEnds: Set<Character> = [".", "!", "?", "\n", "。", "！", "？", "؟"]
    private static let attachedToWord: Set<Character> = ["@", "#", "/", "\\", "_", "-", ":", "$", "%", "&", "=", "+", "~", "`", "*"]

    public static func endsSentence(_ text: String) -> Bool {
        text.last.map { sentenceEnds.contains($0) && !$0.isNewline } ?? false
    }

    /// The word that a space or punctuation has just finished.
    public static func lastWord(in textBefore: String, language: String?) -> Misspelling? {
        guard let last = textBefore.last, last.isWhitespace || last.isPunctuation else { return nil }
        guard let token = tokens(in: Array(textBefore)).last, token.end == textBefore.count - 1 else { return nil }
        return check(token, in: Array(textBefore), language: language)
    }

    /// Every misspelled word in the sentence that ends `textBefore`.
    public static func sentence(endingAt textBefore: String, language: String?) -> [Misspelling] {
        let characters = Array(textBefore)
        var end = characters.count
        while end > 0, characters[end - 1].isWhitespace || sentenceEnds.contains(characters[end - 1]) { end -= 1 }
        var start = end
        while start > 0, !sentenceEnds.contains(characters[start - 1]) { start -= 1 }
        return tokens(in: characters)
            .filter { $0.start >= start && $0.end <= end }
            .compactMap { check($0, in: characters, language: language) }
    }

    struct Token: Equatable {
        var start: Int
        var end: Int
        var word: String
    }

    static func tokens(in characters: [Character]) -> [Token] {
        var result: [Token] = []
        var start: Int?
        for offset in 0...characters.count {
            let inWord = offset < characters.count && isWordCharacter(characters, at: offset, start: start)
            switch (inWord, start) {
            case (true, nil):
                start = offset
            case (false, let wordStart?):
                result.append(Token(start: wordStart, end: offset, word: String(characters[wordStart..<offset])))
                start = nil
            default:
                break
            }
        }
        return result
    }

    private static func isWordCharacter(_ characters: [Character], at offset: Int, start: Int?) -> Bool {
        let character = characters[offset]
        if character.isLetter || character.isNumber { return true }
        guard start != nil, character == "'" || character == "\u{2019}", offset + 1 < characters.count else { return false }
        return characters[offset + 1].isLetter
    }

    static func isCheckable(_ token: Token, in characters: [Character]) -> Bool {
        let word = token.word
        guard word.count >= 3, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else { return false }
        if word.dropFirst().contains(where: \.isUppercase) { return false }
        if let first = word.first, first.isUppercase, !isSentenceStart(token.start, in: characters) { return false }
        if token.start > 0, attachedToWord.contains(characters[token.start - 1]) || characters[token.start - 1] == "." { return false }
        if token.end < characters.count {
            let next = characters[token.end]
            if attachedToWord.contains(next) { return false }
            if next == "." || next == "'", token.end + 1 < characters.count, characters[token.end + 1].isLetter { return false }
        }
        return true
    }

    static func isSentenceStart(_ offset: Int, in characters: [Character]) -> Bool {
        var index = offset - 1
        while index >= 0, characters[index] == " " || characters[index] == "\t" || characters[index] == "\"" || characters[index] == "(" {
            index -= 1
        }
        return index < 0 || sentenceEnds.contains(characters[index])
    }

    private static func check(_ token: Token, in characters: [Character], language: String?) -> Misspelling? {
        guard isCheckable(token, in: characters) else { return nil }
        let checker = NSSpellChecker.shared
        let dictionary = dictionary(for: language)
        let word = token.word
        let misspelled = checker.checkSpelling(
            of: word, startingAt: 0, language: dictionary, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        guard misspelled.location != NSNotFound else { return nil }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let language = dictionary ?? checker.language()
        let correction = checker.correction(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0)
        let guesses = checker.guesses(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: 0) ?? []
        var seen: Set<String> = [word]
        let ordered = ([correction].compactMap { $0 } + guesses)
            .map { matchingCase($0, of: word) }
            .filter { seen.insert($0).inserted }
        return Misspelling(
            word: word, distanceFromEnd: characters.count - token.end, guesses: Array(ordered.prefix(maxGuesses)),
            correction: correction.map { matchingCase($0, of: word) }
        )
    }

    static func matchingCase(_ guess: String, of word: String) -> String {
        guard let first = word.first, first.isUppercase, let guessFirst = guess.first, guessFirst.isLowercase else { return guess }
        return guessFirst.uppercased() + guess.dropFirst()
    }

    static func dictionary(for language: String?) -> String? {
        guard let language else { return nil }
        let available = NSSpellChecker.shared.availableLanguages
        if available.contains(language) { return language }
        let base = language.split(separator: "-").first.map(String.init) ?? language
        if let preferred = Locale.current.region.map({ base + "_" + $0.identifier }), available.contains(preferred) {
            return preferred
        }
        return available.first { $0 == base || $0.hasPrefix(base + "_") }
    }
}
