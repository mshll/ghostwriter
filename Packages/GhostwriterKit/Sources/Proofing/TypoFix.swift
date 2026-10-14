public struct TypoFix: Sendable, Hashable {
    public var word: String
    public var correction: String
    /// Characters from the end of the word to the end of the text, counted in grapheme clusters.
    public var distanceFromEnd: Int

    public init(word: String, correction: String, distanceFromEnd: Int) {
        self.word = word
        self.correction = correction
        self.distanceFromEnd = distanceFromEnd
    }

    /// The end of `text` from the first fixed word on, before and after the fixes; nil if a word is no longer there.
    public static func tail(of text: String, applying fixes: [TypoFix]) -> (original: String, corrected: String)? {
        let original = Array(text)
        var corrected = original
        var tailStart = original.count
        for fix in fixes.sorted(by: { $0.distanceFromEnd < $1.distanceFromEnd }) {
            let end = original.count - fix.distanceFromEnd
            let start = end - fix.word.count
            guard start >= 0, end <= original.count, String(original[start..<end]) == fix.word else { return nil }
            corrected.replaceSubrange(start..<end, with: Array(fix.correction))
            tailStart = min(tailStart, start)
        }
        return (String(original[tailStart...]), String(corrected[tailStart...]))
    }

    /// True when only spaces and punctuation follow the word.
    public func endsText(_ text: String) -> Bool {
        distanceFromEnd <= 3 && text.suffix(distanceFromEnd).allSatisfy { $0.isWhitespace || $0.isPunctuation }
    }
}

extension Misspelling {
    /// The text around the word for scoring: before it with `earlierFixes` applied, after it up to `next`.
    /// Other typos nearby make a model expect more typos.
    public func scoringContext(in text: String, next: Misspelling?, earlierFixes: [TypoFix]) -> (before: String, after: String) {
        let characters = Array(text)
        let end = characters.count - distanceFromEnd
        let start = end - word.count
        let afterEnd = next.map { characters.count - $0.distanceFromEnd - $0.word.count } ?? characters.count
        let before = String(characters[..<max(start, 0)])
        let after = String(characters[min(end, characters.count)..<max(afterEnd, end)])
        let shift = characters.count - start
        let local = earlierFixes.map { TypoFix(word: $0.word, correction: $0.correction, distanceFromEnd: $0.distanceFromEnd - shift) }
        guard !local.isEmpty, let tail = TypoFix.tail(of: before, applying: local) else { return (before, after) }
        return (String(before.dropLast(tail.original.count)) + tail.corrected, after)
    }
}
