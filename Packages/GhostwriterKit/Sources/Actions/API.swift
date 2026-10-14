import Foundation
import FoundationModels
import GWCore

public enum WritingAction: String, Sendable, Codable, CaseIterable, Identifiable {
    case rephrase, fixGrammar, shorten, expand, formal, casual, translate

    public var id: String { rawValue }
}

public struct WritingAssistant: Sendable {
    public init() {}

    public static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in System Settings to use writing actions."
        case .unavailable(.modelNotReady):
            "Apple Intelligence is still getting ready. Try again in a few minutes."
        case .unavailable:
            "Apple Intelligence is unavailable."
        }
    }

    /// Streams the full rewritten text so far. Errors are `WritingAssistantError` (or `CancellationError`).
    public func run(_ action: WritingAction, on text: String, targetLanguage: String? = nil) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let target = try Self.validate(action, text: text, targetLanguage: targetLanguage)
                    let session = LanguageModelSession(
                        model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                        instructions: WritingPrompts.instructions(for: action, targetLanguage: target)
                    )
                    let stream = session.streamResponse(
                        to: WritingPrompts.prompt(for: action, text: text),
                        options: WritingPrompts.options(for: action, text: text)
                    )
                    var latest = ""
                    for try await snapshot in stream {
                        latest = OutputCleaner.partial(snapshot.content, original: text)
                        continuation.yield(latest)
                    }
                    let final = OutputCleaner.final(latest, original: text)
                    if final != latest { continuation.yield(final) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: WritingAssistantError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func prewarm() {
        guard Self.isAvailable else { return }
        LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations)).prewarm()
    }

    public func synonyms(for phrase: String, in context: String) async throws -> [String] {
        let original = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { throw WritingAssistantError.emptyText }
        try Self.checkAvailable()
        let sample = context.isEmpty ? original : context
        try Self.checkLanguage(of: sample)
        let language = LanguageSupport.dominantLanguage(of: sample)
        let session = LanguageModelSession(instructions: WritingPrompts.synonymInstructions)
        do {
            let response = try await session.respond(
                to: WritingPrompts.synonymPrompt(
                    phrase: original, context: context, language: language.map(LanguageSupport.displayName)
                ),
                generating: Alternatives.self,
                options: GenerationOptions(temperature: 0.3)
            )
            let candidates = Alternatives.cleaned(response.content.items, original: original)
            return await SpellFilter.realWords(candidates, language: language)
        } catch {
            throw WritingAssistantError.from(error)
        }
    }

    public func fill(instruction: String, context: String) async throws -> String {
        try Self.checkAvailable()
        let session = LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            instructions: WritingPrompts.fillInstructions
        )
        do {
            let response = try await session.respond(
                to: WritingPrompts.fillPrompt(instruction: instruction, context: context, now: Date()),
                options: GenerationOptions(temperature: 0.6, maximumResponseTokens: 300)
            )
            return OutputCleaner.final(response.content, original: "")
        } catch {
            throw WritingAssistantError.from(error)
        }
    }

    private static func checkAvailable() throws {
        if let reason = unavailableReason { throw WritingAssistantError.unavailable(reason) }
    }

    private static func checkLanguage(of text: String) throws {
        if let language = LanguageSupport.dominantLanguage(of: text), !LanguageSupport.isSupported(language) {
            throw WritingAssistantError.unsupportedLanguage(LanguageSupport.displayName(language))
        }
    }

    private static func validate(_ action: WritingAction, text: String, targetLanguage: String?) throws -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WritingAssistantError.emptyText
        }
        try checkAvailable()
        try checkLanguage(of: text)
        guard action == .translate else { return nil }
        guard let targetLanguage, !targetLanguage.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WritingAssistantError.missingTargetLanguage
        }
        let target = LanguageSupport.resolveTarget(targetLanguage)
        if let code = target.code, !LanguageSupport.isSupported(code) {
            throw WritingAssistantError.unsupportedTargetLanguage(target.name)
        }
        return target.name
    }
}

@Generable
struct Alternatives {
    @Guide(description: "Replacement words or short phrases, best first", .maximumCount(8))
    var items: [String]

    static func cleaned(_ items: [String], original: String) -> [String] {
        var seen: Set<String> = [original.lowercased()]
        let originalWords = Set(original.lowercased().split(whereSeparator: \.isWhitespace))
        let maxWords = originalWords.count + 1
        let capitalize = original.first?.isUppercase ?? false
        return items.compactMap { item -> String? in
            var word = item.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let words = word.lowercased().split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty, words.count <= maxWords else { return nil }
            if originalWords.count == 1, words.contains(where: originalWords.contains) { return nil }
            if capitalize, let first = word.first, first.isLowercase {
                word = first.uppercased() + word.dropFirst()
            }
            return seen.insert(word.lowercased()).inserted ? word : nil
        }
        .prefix(8)
        .map { $0 }
    }
}

enum OutputCleaner {
    private static let quotes: Set<Character> = ["\"", "“", "”", "«", "»", "„", "'"]

    static func partial(_ output: String, original: String) -> String {
        var text = Substring(output)
        while let first = text.first, first.isWhitespace { text = text.dropFirst() }
        if let first = text.first, quotes.contains(first), !(original.first.map(quotes.contains) ?? false) {
            text = text.dropFirst()
        }
        return String(text)
    }

    static func final(_ output: String, original: String) -> String {
        var text = partial(output, original: original).trimmingCharacters(in: .whitespacesAndNewlines)
        let originalEndsQuoted = original.trimmingCharacters(in: .whitespacesAndNewlines).last.map(quotes.contains) ?? false
        if let last = text.last, quotes.contains(last), !originalEndsQuoted, quoteCount(text) % 2 == 1 {
            text.removeLast()
        }
        return text
    }

    private static func quoteCount(_ text: String) -> Int {
        let characters = Array(text)
        return characters.indices.filter { index in
            guard quotes.contains(characters[index]) else { return false }
            let isApostrophe = (characters[index] == "'" || characters[index] == "\u{2019}")
                && index > 0 && index + 1 < characters.count
                && characters[index - 1].isLetter && characters[index + 1].isLetter
            return !isApostrophe
        }.count
    }
}

public struct SnippetMatch: Sendable, Hashable {
    public var snippet: Snippet
    /// Characters to delete before inserting (the typed trigger), counted in grapheme clusters:
    /// one Backspace press each.
    public var triggerLength: Int
}

public struct SnippetExpansion: Sendable, Hashable {
    public var text: String
    /// Counted in grapheme clusters (Swift `Character`s): one Left-arrow press each.
    public var cursorOffsetFromEnd: Int
}

public struct SnippetEngine: Sendable {
    public var snippets: [Snippet]
    public var locale: Locale = .autoupdatingCurrent
    public var timeZone: TimeZone = .autoupdatingCurrent

    public init(snippets: [Snippet]) {
        self.snippets = snippets
    }

    public init(snippets: [Snippet], locale: Locale, timeZone: TimeZone) {
        self.snippets = snippets
        self.locale = locale
        self.timeZone = timeZone
    }

    public func match(typedTail: String) -> SnippetMatch? {
        snippets
            .filter { $0.isEnabled && !$0.trigger.isEmpty && Self.endsAtWordStart(typedTail, trigger: $0.trigger) }
            .max { $0.trigger.count < $1.trigger.count }
            .map { SnippetMatch(snippet: $0, triggerLength: $0.trigger.count) }
    }

    public static func usesClipboard(_ snippet: Snippet) -> Bool {
        SnippetTemplate.parse(snippet.body).contains { if case .clipboard = $0 { true } else { false } }
    }

    public func expand(
        _ snippet: Snippet, clipboard: String?, now: Date,
        ai: @Sendable (String) async -> String
    ) async -> SnippetExpansion {
        let pieces = SnippetTemplate.parse(snippet.body)
        let instructions = pieces.compactMap { piece -> String? in
            if case .ai(let instruction) = piece { return instruction }
            return nil
        }
        let answers = await withoutActuallyEscaping(ai) { ai in
            await Self.fillConcurrently(instructions, ai: ai)
        }

        var before = ""
        var after: String?
        var nextAnswer = 0
        for piece in pieces {
            let text: String
            switch piece {
            case .text(let literal): text = literal
            case .date(let format): text = format.map { formatted(now, as: $0) } ?? now.formatted(dateStyle)
            case .time(let format): text = format.map { formatted(now, as: $0) } ?? now.formatted(timeStyle)
            case .clipboard: text = clipboard ?? ""
            case .ai:
                text = answers[nextAnswer]
                nextAnswer += 1
            case .cursor:
                if after == nil { after = "" }
                continue
            }
            if after == nil { before += text } else { after? += text }
        }
        let tail = after ?? ""
        return SnippetExpansion(text: before + tail, cursorOffsetFromEnd: tail.count)
    }

    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(date: .long, time: .omitted, locale: locale, timeZone: timeZone)
    }

    private var timeStyle: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
    }

    private func formatted(_ date: Date, as format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func fillConcurrently(_ instructions: [String], ai: @escaping @Sendable (String) async -> String) async -> [String] {
        await withTaskGroup(of: (Int, String).self) { group in
            for (index, instruction) in instructions.enumerated() {
                group.addTask { (index, await ai(instruction)) }
            }
            var answers = Array(repeating: "", count: instructions.count)
            for await (index, answer) in group { answers[index] = answer }
            return answers
        }
    }

    private static let openingPunctuation: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "«", "¿", "¡"]

    static func endsAtWordStart(_ tail: String, trigger: String) -> Bool {
        guard tail.hasSuffix(trigger) else { return false }
        guard let previous = tail.dropLast(trigger.count).last else { return true }
        if previous.isWhitespace || openingPunctuation.contains(previous) { return true }
        let triggerStartsWord = trigger.first.map { $0.isLetter || $0.isNumber } ?? false
        return triggerStartsWord && !(previous.isLetter || previous.isNumber || previous == "_")
    }
}
