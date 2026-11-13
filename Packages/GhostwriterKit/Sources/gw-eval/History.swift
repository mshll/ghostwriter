import Foundation
import Inference
import Memory
import Prompting

struct HistorySession: Decodable {
    var id: String
    var bundle: String
    var domain: String?
    var label: String?
    var lang: String?
    var date: Date
    var text: String
}

/// Examples and word-follower bias from a writing history, built as `CompletionCoordinator` builds them.
/// The query shape, follower limit and defaults copy `ContextRequest.examples` and `CompletionCoordinator.bias(for:)`
/// in the app target, which this package cannot import; keep them in sync.
struct Personalization {
    static let appExampleLimit = 2
    static let appBiasStrength = 1.5
    static let queryCharacters = 600
    static let followerLimit = 8

    var memory: MemoryStore
    var exampleLimit = appExampleLimit
    var biasStrength = appBiasStrength
    var ranking = ExampleRanking()

    static func load(_ url: URL) throws -> MemoryStore {
        let memory = try MemoryStore.inMemory()
        for session in try decodeLines(HistorySession.self, from: url) {
            try memory.upsertSession(WritingSession(
                key: session.id, bundleID: session.bundle, domain: session.domain, fieldLabel: session.label,
                text: session.text, language: session.lang, updatedAt: session.date
            ))
        }
        return memory
    }

    func examples(for row: Row) throws -> [String] {
        let query = String(row.before.suffix(Self.queryCharacters))
        return try memory.examples(
            query: query, bundleID: row.bundle ?? "", language: LanguageDetector.dominantLanguage(of: query),
            limit: exampleLimit, excludingKey: nil, now: row.date ?? .now, ranking: ranking
        )
    }

    func bias(language: String?) throws -> TokenBias? {
        guard biasStrength > 0 else { return nil }
        let followers = try memory.followers(language: language, limit: Self.followerLimit)
        return followers.isEmpty ? nil : TokenBias(followers: followers, strength: biasStrength)
    }
}
