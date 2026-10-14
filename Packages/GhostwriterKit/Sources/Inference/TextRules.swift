import Foundation

enum SentenceEnd: Equatable {
    case none
    case definite
    case ambiguous
}

enum TextRules {
    private static let definiteTerminators: Set<Character> = ["!", "?", "。", "！", "？", "؟", "…", "۔", "।", "｡"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "”", "’", "»", "」", "』", "）", "】"]
    private static let joiners: Set<Character> = ["'", "’", "-"]
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "inc", "ltd", "jr", "sr", "approx", "no", "fig", "dept",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "sr", "sra", "bzw", "usw",
        "z", "ca", "nr",
    ]

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func hasWordCharacter(_ text: String) -> Bool {
        text.contains(where: isWordCharacter)
    }

    /// Words in `text`; CJK characters count half a word each because those scripts have no spaces.
    static func wordUnits(_ text: String) -> Double {
        var units = 0.0
        var inWord = false
        for character in text {
            if isCJK(character) {
                units += 0.5
                inWord = false
            } else if isWordCharacter(character) {
                if !inWord { units += 1 }
                inWord = true
            } else if !(inWord && joiners.contains(character)) {
                inWord = false
            }
        }
        return units
    }

    static func sentenceEnd(of text: String) -> SentenceEnd {
        var body = Substring(text)
        while let last = body.last, closers.contains(last) { body = body.dropLast() }
        guard let last = body.last else { return .none }
        if definiteTerminators.contains(last) { return .definite }
        guard last == "." else { return .none }
        let beforePeriod = body.dropLast()
        guard let previous = beforePeriod.last else { return .definite }
        if previous == "." { return .definite }
        if previous.isNumber { return .ambiguous }
        let word = beforePeriod.reversed().prefix { $0.isLetter }
        if word.count == 1 || abbreviations.contains(String(word.reversed()).lowercased()) { return .ambiguous }
        return .definite
    }

    static func continuesWord(_ piece: String) -> Bool {
        guard let first = piece.first else { return false }
        return !isCJK(first) && (isWordCharacter(first) || joiners.contains(first))
    }

    static func trimmingPartialWord(_ text: String) -> String {
        guard let last = text.last, isWordCharacter(last), !isCJK(last) else { return text }
        var trimmed = Substring(text)
        while let last = trimmed.last, !isCJK(last), isWordCharacter(last) || joiners.contains(last) {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }

    static func lastWord(of text: String) -> String? {
        let body = text.reversed().drop { $0 == " " || $0 == "\t" }
        guard let last = body.first, isWordCharacter(last), !isCJK(last) else { return nil }
        let word = body.prefix { isWordCharacter($0) || joiners.contains($0) }
        return String(word.reversed())
    }

    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            if isCJK(character) {
                if !current.isEmpty { words.append(current) }
                words.append(String(character))
                current = ""
            } else if isWordCharacter(character) || (!current.isEmpty && joiners.contains(character)) {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    static func repeatsLastBigram(_ text: String) -> Bool {
        let words = words(text)
        guard words.count >= 3 else { return false }
        let last = words.suffix(2)
        return zip(words, words.dropFirst()).dropLast().contains { $0 == last.first && $1 == last.last }
    }

    static let echoWords = 8
    static let echoCharacters = 40

    static func wordGrams(_ words: [String], length: Int) -> Set<String> {
        guard words.count >= length else { return [] }
        return Set((0...(words.count - length)).map { words[$0..<($0 + length)].joined(separator: " ") })
    }

    static func echoStart(_ text: String, source: String, sourceGrams: Set<String>) -> String.Index? {
        let words = words(text)
        if words.count >= echoWords {
            let span = words.suffix(echoWords).joined(separator: " ")
            if sourceGrams.contains(span) || wordGrams(Array(words.dropLast()), length: echoWords).contains(span) {
                let starts = wordStarts(text)
                return starts.count >= echoWords ? starts[starts.count - echoWords] : text.startIndex
            }
        }
        guard text.count >= echoCharacters else { return nil }
        let start = text.index(text.endIndex, offsetBy: -echoCharacters)
        let tail = text[start...]
        return source.contains(tail) || text.dropLast().contains(tail) ? start : nil
    }

    static func echoes(_ text: String, source: String, sourceGrams: Set<String>) -> Bool {
        echoStart(text, source: source, sourceGrams: sourceGrams) != nil
    }

    /// Start index of every word, split the same way as `words(_:)`.
    static func wordStarts(_ text: String) -> [String.Index] {
        var starts: [String.Index] = []
        var inWord = false
        for index in text.indices {
            let character = text[index]
            if isCJK(character) {
                starts.append(index)
                inWord = false
            } else if isWordCharacter(character) {
                if !inWord { starts.append(index) }
                inWord = true
            } else if !(inWord && joiners.contains(character)) {
                inWord = false
            }
        }
        return starts
    }

    static func trimmingToBoundary(_ text: String) -> String {
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == "\n" { return String(text[..<previous]) }
            if index < text.endIndex, text[index].isWhitespace, sentenceEnd(of: String(text[..<index])) == .definite {
                return String(text[..<index])
            }
            index = previous
        }
        return trimmingPartialWord(text)
    }

    static func clashes(insertion: String, before after: String) -> Bool {
        let next = after.drop { $0 == " " }.first
        if sentenceEnd(of: insertion) != .none, let next, next.isLowercase || next.isNumber { return true }
        if let last = insertion.last(where: { $0 != " " }), let next, last.isPunctuation, last == next { return true }
        let inserted = words(insertion)
        let following = Array(words(after).prefix(6))
        guard let lastInserted = inserted.last, let firstFollowing = following.first else { return false }
        if lastInserted == firstFollowing { return true }
        let followingPairs = Set(zip(following, following.dropFirst()).map { "\($0) \($1)" })
        return zip(inserted, inserted.dropFirst()).contains { followingPairs.contains("\($0) \($1)") }
    }

    static func containsBlankLine<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> Bool {
        var afterNewline = false
        for byte in bytes {
            if byte == 0x0A {
                if afterNewline { return true }
                afterNewline = true
            } else if byte != 0x20 && byte != 0x09 {
                afterNewline = false
            }
        }
        return false
    }

    static func insertion(_ text: String, before after: String) -> String {
        guard let next = after.first, isWordCharacter(next), !isCJK(next),
              let last = text.last, !last.isWhitespace, !isCJK(last)
        else { return text }
        return text + " "
    }

    static func truncatingAtRepeatedLine(_ text: String) -> String {
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let key = line.trimmingCharacters(in: .whitespaces)
            if key.count >= 8, !seen.insert(key).inserted { return String(text[..<line.startIndex]) }
        }
        return text
    }

    static func endsWithSpaceAfterText(_ text: String) -> Bool {
        guard let last = text.last, last.isWhitespace, !last.isNewline else { return false }
        return text.reversed().prefix { !$0.isNewline }.contains { !$0.isWhitespace }
    }

    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// Splits trailing spaces off the prompt so the model writes them itself, joined to the next word as most tokenizers expect.
    static func splitTrailingSpaces(_ prompt: String) -> (prompt: String, spaces: String) {
        let body = prompt.reversed().drop { $0 == " " }
        let spaces = prompt.count - body.count
        return (String(prompt.dropLast(spaces)), String(repeating: " ", count: spaces))
    }

    static func decodeComplete<Bytes: BidirectionalCollection<UInt8>>(_ bytes: Bytes) -> String {
        var end = bytes.endIndex
        var index = end
        var trailing = 0
        while index > bytes.startIndex, trailing < 4 {
            index = bytes.index(before: index)
            let byte = bytes[index]
            if byte & 0xC0 != 0x80 {
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                if length > trailing + 1 { end = index }
                break
            }
            trailing += 1
        }
        return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
    }
}

func commonPrefixLength<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
    var count = 0
    let limit = min(a.count, b.count)
    while count < limit, a[count] == b[count] { count += 1 }
    return count
}

func pieceSatisfies<P: Collection<UInt8>, R: Collection<UInt8>>(_ piece: P, _ required: R) -> Bool {
    guard !piece.isEmpty else { return false }
    return piece.starts(with: required) || required.starts(with: piece)
}
