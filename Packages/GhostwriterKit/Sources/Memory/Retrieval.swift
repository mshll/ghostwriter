import Foundation
import GRDB

extension MemoryStore {
    static let minimumExampleLength = 100
    static let sameAppBoost = 1.5
    static let recencyBoost = 0.2
    static let recencyHalfLife: TimeInterval = 30 * 24 * 3_600

    struct Hit {
        var bundleID: String
        var text: String
        var updatedAt: Date
        var relevance: Double
    }

    public func examples(
        query: String, bundleID: String, language: String?, limit: Int, excludingKey: String?
    ) throws -> [String] {
        try examples(query: query, bundleID: bundleID, language: language, limit: limit, excludingKey: excludingKey, now: .now)
    }

    func examples(
        query: String, bundleID: String, language: String?, limit: Int, excludingKey: String?, now: Date
    ) throws -> [String] {
        guard limit > 0 else { return [] }
        let terms = SearchTerms(query: query)
        let candidates = max(20, limit * 5)
        var hits: [Hit] = []
        if !terms.isEmpty {
            hits = try matches(for: terms, language: language, excludingKey: excludingKey, limit: candidates)
            hits = Self.rank(hits, bundleID: bundleID, now: now)
        }
        if hits.isEmpty {
            hits = try recent(bundleID: bundleID, language: language, excludingKey: excludingKey, limit: candidates)
        }
        return Passages.select(from: hits.map(\.text), terms: Set(terms.words), limit: limit)
    }

    private func matches(for terms: SearchTerms, language: String?, excludingKey: String?, limit: Int) throws -> [Hit] {
        try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT s.bundleID, s.text, s.updatedAt, bm25(writing_sessions_ft) AS rank
                    FROM writing_sessions_ft
                    JOIN writing_sessions s ON s.id = writing_sessions_ft.rowid
                    WHERE writing_sessions_ft MATCH :pattern
                      AND length(s.text) >= :minimumLength
                      AND (:excludedKey IS NULL OR s.key <> :excludedKey)
                      AND (:language IS NULL OR s.language = :language)
                    ORDER BY rank
                    LIMIT :limit
                    """,
                arguments: [
                    "pattern": terms.pattern, "minimumLength": Self.minimumExampleLength,
                    "excludedKey": excludingKey, "language": language, "limit": limit,
                ]
            ).map { row in
                Hit(bundleID: row["bundleID"], text: row["text"], updatedAt: row["updatedAt"], relevance: -(row["rank"] as Double))
            }
        }
    }

    private func recent(bundleID: String, language: String?, excludingKey: String?, limit: Int) throws -> [Hit] {
        try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT bundleID, text, updatedAt FROM writing_sessions
                    WHERE length(text) >= :minimumLength
                      AND (:excludedKey IS NULL OR key <> :excludedKey)
                      AND (:language IS NULL OR language = :language)
                    ORDER BY bundleID = :bundleID DESC, updatedAt DESC
                    LIMIT :limit
                    """,
                arguments: [
                    "minimumLength": Self.minimumExampleLength, "excludedKey": excludingKey,
                    "language": language, "bundleID": bundleID, "limit": limit,
                ]
            ).map { row in
                Hit(bundleID: row["bundleID"], text: row["text"], updatedAt: row["updatedAt"], relevance: 0)
            }
        }
    }

    static func rank(_ hits: [Hit], bundleID: String, now: Date) -> [Hit] {
        func score(_ hit: Hit) -> Double {
            let age = max(0, now.timeIntervalSince(hit.updatedAt))
            let recency = 1 + recencyBoost * exp2(-age / recencyHalfLife)
            return hit.relevance * (hit.bundleID == bundleID ? sameAppBoost : 1) * recency
        }
        return hits
            .map { (hit: $0, score: score($0)) }
            .sorted { ($0.score, $0.hit.updatedAt) > ($1.score, $1.hit.updatedAt) }
            .map(\.hit)
    }
}

struct SearchTerms {
    static let maximumCount = 30
    static let minimumLength = 3

    let words: [String]

    init(query: String) {
        var seen: Set<String> = []
        var picked: [String] = []
        for word in Words.spans(in: Array(query)).map(\.word).reversed() {
            guard picked.count < Self.maximumCount else { break }
            guard Self.isDistinctive(word), seen.insert(word).inserted else { continue }
            picked.append(word)
        }
        words = picked.reversed()
    }

    private static func isDistinctive(_ word: String) -> Bool {
        if word.contains(where: \.isUnsegmentedScript) { return true }
        return word.count >= minimumLength && !word.allSatisfy(\.isNumber) && !Stopwords.all.contains(word)
    }

    var isEmpty: Bool { words.isEmpty }

    var pattern: String {
        words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
    }
}

enum Passages {
    static let length = 400
    static let reach = 150
    static let wordReach = 30
    static let duplicateSimilarity = 0.6

    static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "؟"]
    static let fullWidthSentenceEnds: Set<Character> = ["。", "！", "？"]

    static func select(from texts: [String], terms: Set<String>, limit: Int) -> [String] {
        var picked: [String] = []
        var pickedWords: [Set<String>] = []
        for text in texts {
            let passage = best(in: text, terms: terms)
            guard !passage.text.isEmpty,
                  !pickedWords.contains(where: { similarity($0, passage.words) >= duplicateSimilarity })
            else { continue }
            picked.append(passage.text)
            pickedWords.append(passage.words)
            if picked.count == limit { break }
        }
        return picked
    }

    static func best(in text: String, terms: Set<String>) -> (text: String, words: Set<String>) {
        let characters = Array(text)
        let spans = Words.spans(in: characters)
        var lower = 0
        var upper = characters.count
        if characters.count > length + reach {
            (lower, upper) = window(count: characters.count, hits: spans.filter { terms.contains($0.word) })
            lower = sentenceStart(in: characters, atOrBefore: lower)
            upper = sentenceEnd(in: characters, atOrAfter: upper)
        }
        let passage = String(characters[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Set(spans.filter { $0.range.lowerBound >= lower && $0.range.upperBound <= upper }.map(\.word))
        return (passage, words)
    }

    static func window(count: Int, hits: [Words.Span]) -> (Int, Int) {
        guard !hits.isEmpty else { return (count - length, count) }
        var best = (lower: 0, upper: 0, distinct: 0, total: 0)
        var end = 0
        for start in hits.indices {
            end = max(end, start)
            while end < hits.count, hits[end].range.upperBound - hits[start].range.lowerBound <= length { end += 1 }
            guard end > start else { continue }
            let cluster = hits[start..<end]
            let distinct = Set(cluster.map(\.word)).count
            if (distinct, cluster.count) > (best.distinct, best.total) {
                best = (hits[start].range.lowerBound, hits[end - 1].range.upperBound, distinct, cluster.count)
            }
        }
        let padding = max(0, length - (best.upper - best.lower)) / 2
        let lower = max(0, min(best.lower - padding, count - length))
        return (lower, min(count, lower + length))
    }

    static func sentenceStart(in characters: [Character], atOrBefore position: Int) -> Int {
        let sentenceLimit = max(0, position - reach)
        for start in stride(from: position, through: sentenceLimit, by: -1) where startsSentence(characters, at: start) {
            return start
        }
        let wordLimit = max(0, position - wordReach)
        for start in stride(from: position, through: wordLimit, by: -1) where start == 0 || characters[start - 1].isWhitespace {
            return start
        }
        return position
    }

    static func sentenceEnd(in characters: [Character], atOrAfter position: Int) -> Int {
        let sentenceLimit = min(characters.count, position + reach)
        for end in position...sentenceLimit where endsSentence(characters, at: end) {
            return end
        }
        let wordLimit = min(characters.count, position + wordReach)
        for end in position...wordLimit where end == characters.count || characters[end].isWhitespace {
            return end
        }
        return position
    }

    private static func startsSentence(_ characters: [Character], at start: Int) -> Bool {
        guard start > 0 else { return true }
        let previous = characters[start - 1]
        return previous.isNewline || fullWidthSentenceEnds.contains(previous)
            || (previous.isWhitespace && start >= 2 && sentenceEnds.contains(characters[start - 2]))
    }

    private static func endsSentence(_ characters: [Character], at end: Int) -> Bool {
        guard end < characters.count else { return true }
        guard end > 0 else { return false }
        let last = characters[end - 1]
        return characters[end].isNewline || fullWidthSentenceEnds.contains(last)
            || (sentenceEnds.contains(last) && characters[end].isWhitespace)
    }

    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 1 : Double(a.intersection(b).count) / Double(union)
    }
}
