import Foundation
import GRDB

struct FollowersKey: Hashable {
    var language: String?
    var limit: Int
}

extension MemoryStore {
    static let followerSessionLimit = 500
    static let minimumPairCount = 2

    public func followers(language: String?, limit: Int) throws -> [String: [String: Double]] {
        guard limit > 0 else { return [:] }
        let key = FollowersKey(language: language, limit: limit)
        let (cached, generation) = state.withLock { ($0.followers[key], $0.writingGeneration) }
        if let cached { return cached }
        let texts = try writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT text FROM writing_sessions
                    WHERE :language IS NULL OR language = :language
                    ORDER BY updatedAt DESC LIMIT :limit
                    """,
                arguments: ["language": language, "limit": Self.followerSessionLimit]
            )
        }
        let table = Bigrams.followers(in: texts, limit: limit, minimumCount: Self.minimumPairCount)
        state.withLock { state in
            if state.writingGeneration == generation { state.followers[key] = table }
        }
        return table
    }
}

enum Bigrams {
    static let breaks: Set<Character> = [".", "!", "?", "…", "؟", "。", "！", "？", ";", ":"]

    static func followers(in texts: [String], limit: Int, minimumCount: Int) -> [String: [String: Double]] {
        var counts: [String: [String: Int]] = [:]
        for text in texts {
            var previous: String?
            var lastEnd = text.startIndex
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
                defer { lastEnd = range.upperBound }
                guard let word else { return }
                if text[lastEnd..<range.lowerBound].contains(where: { $0.isNewline || breaks.contains($0) }) {
                    previous = nil
                }
                guard let first = word.first, !first.isNumber else {
                    previous = nil
                    return
                }
                let current = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                if let previous { counts[previous, default: [:]][current, default: 0] += 1 }
                previous = current
            }
        }
        var table: [String: [String: Double]] = [:]
        for (word, next) in counts {
            let total = Double(next.values.reduce(0, +))
            let kept = next
                .filter { $0.value >= minimumCount }
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(limit)
            guard !kept.isEmpty else { continue }
            table[word] = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, Double($0.value) / total) })
        }
        return table
    }
}
