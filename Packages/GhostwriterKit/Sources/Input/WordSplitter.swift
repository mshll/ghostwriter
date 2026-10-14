import Foundation

public enum WordSplitter {
    public static func nextChunk(of suggestion: String, includeTrailingSpace: Bool, includeTrailingPunctuation: Bool) -> String {
        let end = suggestion.endIndex
        let wordStart = suggestion.firstIndex { !$0.isWhitespace } ?? end
        guard wordStart < end else { return suggestion }
        let runEnd = suggestion[wordStart...].firstIndex(where: \.isWhitespace) ?? end

        var wordEnd = runEnd
        if suggestion[wordStart..<runEnd].contains(where: isUnspacedScript) {
            wordEnd = firstWordEnd(in: suggestion, range: wordStart..<runEnd) ?? runEnd
        }

        var chunkEnd: String.Index
        if includeTrailingPunctuation {
            chunkEnd = suggestion[wordEnd...].firstIndex { !isPunctuation($0) } ?? end
        } else {
            chunkEnd = wordEnd
            while chunkEnd > wordStart, isPunctuation(suggestion[suggestion.index(before: chunkEnd)]) {
                chunkEnd = suggestion.index(before: chunkEnd)
            }
            if chunkEnd == wordStart {
                chunkEnd = wordEnd
            }
        }

        if includeTrailingSpace {
            chunkEnd = suggestion[chunkEnd...].firstIndex { !$0.isWhitespace || $0.isNewline } ?? end
        }
        return String(suggestion[..<chunkEnd])
    }

    private static func firstWordEnd(in text: String, range: Range<String.Index>) -> String.Index? {
        var result: String.Index?
        text.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, wordRange, _, stop in
            result = wordRange.upperBound
            stop = true
        }
        return result
    }

    static func isPunctuation(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        let isEmoji = scalars.contains { $0.properties.isEmojiPresentation || $0 == "\u{FE0F}" }
        return !isEmoji && !character.isWhitespace && scalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }
    }

    private static let unspacedScriptRanges: [ClosedRange<UInt32>] = [
        0x0E00...0x0EFF,
        0x0F00...0x0FFF,
        0x1000...0x109F,
        0x1780...0x17FF,
        0x3040...0x30FF,
        0x31F0...0x31FF,
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xF900...0xFAFF,
        0xFF66...0xFF9F,
        0x20000...0x3FFFF,
    ]

    private static func isUnspacedScript(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return unspacedScriptRanges.contains { $0.contains(value) }
    }
}
