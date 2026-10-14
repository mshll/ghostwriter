import Foundation
import GWCore

public struct WritingSession: Sendable, Hashable {
    public var key: String
    public var bundleID: String
    public var domain: String?
    public var fieldLabel: String?
    public var text: String
    public var language: String?
    public var updatedAt: Date

    public init(
        key: String, bundleID: String, domain: String? = nil, fieldLabel: String? = nil,
        text: String, language: String? = nil, updatedAt: Date = .now
    ) {
        self.key = key
        self.bundleID = bundleID
        self.domain = domain
        self.fieldLabel = fieldLabel
        self.text = text
        self.language = language
        self.updatedAt = updatedAt
    }
}

public struct AcceptanceEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable { case word, full, typo, emoji, snippet, action, draft }

    public var kind: Kind
    public var bundleID: String
    public var words: Int
    public var characters: Int
    public var date: Date

    public init(kind: Kind, bundleID: String, words: Int, characters: Int, date: Date = .now) {
        self.kind = kind
        self.bundleID = bundleID
        self.words = words
        self.characters = characters
        self.date = date
    }
}

public struct DailyStat: Sendable, Hashable, Identifiable {
    public var day: Date
    public var wordsAccepted: Int
    public var charactersAccepted: Int
    public var acceptances: Int

    public var id: Date { day }
}

public struct AppStat: Sendable, Hashable, Identifiable {
    public var bundleID: String
    public var wordsAccepted: Int
    public var acceptances: Int
    public var suggestionsShown: Int
    public var suggestionsUsed: Int

    public var id: String { bundleID }
}

public struct KindStat: Sendable, Hashable, Identifiable {
    public var kind: AcceptanceEvent.Kind
    public var wordsAccepted: Int
    public var acceptances: Int

    public var id: AcceptanceEvent.Kind { kind }
}

public enum SuggestionOutcome: Sendable {
    case shown, used
}

public enum MemoryError: Error, Equatable {
    case duplicateSnippetTrigger(String)
}
