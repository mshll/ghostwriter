import Foundation

/// Word splitting that matches the full-text index: letters, marks and digits form words, and words
/// compare lowercased without Latin diacritics. Runs in scripts written without spaces split into
/// overlapping character pairs, which the index keeps in its `bigrams` column.
enum Words {
    struct Span {
        var range: Range<Int>
        var word: String
    }

    static func spans(in characters: [Character]) -> [Span] {
        runs(in: characters).flatMap { pieces(of: $0, in: characters) }
    }

    static func indexedBigrams(in text: String) -> String {
        let characters = Array(text)
        return runs(in: characters)
            .filter { characters[$0].contains(where: \.isUnsegmentedScript) }
            .flatMap { pieces(of: $0, in: characters) }
            .map(\.word)
            .joined(separator: " ")
    }

    private static func runs(in characters: [Character]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for offset in 0...characters.count {
            let inWord = offset < characters.count && characters[offset].isWordCharacter
            switch (inWord, start) {
            case (true, nil):
                start = offset
            case (false, let wordStart?):
                runs.append(wordStart..<offset)
                start = nil
            default:
                break
            }
        }
        return runs
    }

    private static func pieces(of run: Range<Int>, in characters: [Character]) -> [Span] {
        var spans: [Span] = []
        var start = run.lowerBound
        while start < run.upperBound {
            let unsegmented = characters[start].isUnsegmentedScript
            var end = start + 1
            while end < run.upperBound, characters[end].isUnsegmentedScript == unsegmented { end += 1 }
            let ranges = !unsegmented || end - start == 1 ? [start..<end] : (start..<(end - 1)).map { $0..<($0 + 2) }
            spans += ranges.map { Span(range: $0, word: fold(String(characters[$0]))) }
            start = end
        }
        return spans
    }

    static func fold(_ word: some StringProtocol) -> String {
        let lowered = word.lowercased()
        guard lowered.utf8.contains(where: { $0 >= 0x80 }) else { return lowered }
        return lowered.folding(options: .diacriticInsensitive, locale: nil)
    }
}

extension Character {
    var isWordCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber,
             .privateUse:
            return true
        default:
            return false
        }
    }

    var isUnsegmentedScript: Bool {
        guard let value = unicodeScalars.first?.value else { return false }
        switch value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF,
             0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

enum Stopwords {
    static let all: Set<String> = Set([
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our",
        "out", "has", "him", "his", "how", "its", "now", "see", "who", "did", "get", "got", "let", "say", "she",
        "too", "use", "that", "with", "have", "this", "will", "your", "from", "they", "know", "want", "been",
        "some", "very", "when", "here", "just", "like", "more", "only", "than", "them", "well", "were", "what",
        "then", "there", "these", "those", "would", "could", "should", "about", "after", "again", "also",
        "because", "before", "being", "which", "while", "where", "their", "into", "other", "much", "does",
        "und", "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "ist", "sind",
        "war", "mit", "auf", "für", "von", "nicht", "sich", "auch", "wie", "aber", "wenn", "dass", "oder", "noch",
        "nur", "bei", "aus", "nach", "ich", "wir", "ihr", "sie", "mir", "mich", "dir", "dich", "uns", "euch",
        "ihm", "hat", "habe", "haben", "wird", "werden", "kann", "schon", "sehr", "dann", "als", "was", "wer",
        "que", "los", "las", "del", "una", "uno", "unos", "por", "con", "para", "como", "más", "pero", "sus",
        "este", "esta", "esto", "eso", "ese", "son", "fue", "muy", "hay", "sin", "sobre", "todo", "también",
        "cuando", "porque", "entre", "donde",
        "les", "une", "est", "qui", "dans", "pour", "pas", "sur", "avec", "son", "ses", "aux", "par", "plus",
        "mais", "comme", "cette", "ces", "tout", "nous", "vous", "ils", "elle", "elles", "leur", "sont", "ont",
        "été", "être", "avoir", "fait", "bien",
        "على", "الى", "إلى", "هذا", "هذه", "ذلك", "التي", "الذي", "كان", "كانت", "بعد", "قبل", "عند", "حتى",
        "انا", "أنا", "نحن", "لكن", "يكون", "ايضا", "أيضا",
    ].map(Words.fold))
}
