struct EmojiIndex {
    struct Entry {
        let emoji: String
        let name: String
        let words: [Substring]
    }

    static let shared = EmojiIndex()

    private let entries: [Entry]

    private init() {
        let ranges: [ClosedRange<UInt32>] = [0x2600...0x27BF, 0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF]
        entries = ranges.flatMap { $0 }.compactMap { value in
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation,
                  let name = scalar.properties.name?.lowercased() else { return nil }
            return Entry(emoji: String(scalar), name: name, words: name.split(separator: " "))
        }
    }

    func search(_ query: String, limit: Int = 9) -> [Entry] {
        let terms = query.lowercased().split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" })
        guard !terms.isEmpty else { return [] }
        return entries
            .filter { entry in terms.allSatisfy { term in entry.words.contains { $0.hasPrefix(term) } } }
            .sorted { $0.name.count < $1.name.count }
            .prefix(limit)
            .map { $0 }
    }

    static func pendingQuery(in textBefore: String) -> String? {
        guard let colon = textBefore.lastIndex(of: ":") else { return nil }
        let query = textBefore[textBefore.index(after: colon)...]
        let precededByBoundary = colon == textBefore.startIndex || textBefore[textBefore.index(before: colon)].isWhitespace
        guard precededByBoundary, query.count >= 2, query.allSatisfy(isQueryCharacter) else { return nil }
        return String(query)
    }

    static func isQueryCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }
}
