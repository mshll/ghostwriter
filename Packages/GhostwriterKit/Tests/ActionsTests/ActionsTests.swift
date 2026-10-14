import Foundation
import GWCore
import Testing
@testable import Actions

private func engine(_ triggers: [String], disabled: Set<String> = []) -> SnippetEngine {
    SnippetEngine(snippets: triggers.map { Snippet(trigger: $0, body: "body of \($0)", isEnabled: !disabled.contains($0)) })
}

private func expand(
    _ body: String, clipboard: String? = nil, now: Date = Date(timeIntervalSince1970: 1_791_720_000),
    ai: @Sendable (String) async -> String = { "<\($0)>" }
) async -> SnippetExpansion {
    let engine = SnippetEngine(
        snippets: [], locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!
    )
    return await engine.expand(Snippet(trigger: ";x", body: body), clipboard: clipboard, now: now, ai: ai)
}

@Suite struct SnippetMatching {
    @Test func matchesAtStartOfTail() {
        let match = engine([";addr"]).match(typedTail: ";addr")
        #expect(match?.snippet.trigger == ";addr")
        #expect(match?.triggerLength == 5)
    }

    @Test func matchesAfterWhitespaceOrNewline() {
        #expect(engine([";addr"]).match(typedTail: "my address is ;addr") != nil)
        #expect(engine([":sig"]).match(typedTail: "Thanks\n:sig") != nil)
    }

    @Test func matchesAfterOpeningPunctuation() {
        #expect(engine(["/date"]).match(typedTail: "(/date") != nil)
    }

    @Test func rejectsTriggerGluedToPrecedingWord() {
        #expect(engine([";addr"]).match(typedTail: "hello;addr") == nil)
        #expect(engine(["/date"]).match(typedTail: "example.com/date") == nil)
        #expect(engine(["addr"]).match(typedTail: "myaddr") == nil)
    }

    @Test func letterTriggerMatchesAfterPunctuation() {
        #expect(engine(["brb"]).match(typedTail: "ok.brb") != nil)
    }

    @Test func requiresTriggerAtEndOfTail() {
        #expect(engine([";addr"]).match(typedTail: ";addr ") == nil)
        #expect(engine([";addr"]).match(typedTail: ";add") == nil)
    }

    @Test func longestTriggerWins() {
        let match = engine([";a", "a", ";addr", "addr"]).match(typedTail: "see ;addr")
        #expect(match?.snippet.trigger == ";addr")
    }

    @Test func disabledSnippetsAreIgnored() {
        let snippets = engine([";addr", ";sig"], disabled: [";addr"])
        #expect(snippets.match(typedTail: " ;addr") == nil)
        #expect(snippets.match(typedTail: " ;sig")?.snippet.trigger == ";sig")
    }

    @Test func emptyTriggerNeverMatches() {
        #expect(engine([""]).match(typedTail: "anything") == nil)
    }

    @Test(arguments: [
        (";عنوان", "اكتب ;عنوان", 6),
        ("→é", "x →é", 2),
        (":🙂sig", "hi :🙂sig", 5),
        (":👩‍💻", ":👩‍💻", 2),
    ])
    func unicodeTriggersCountGraphemes(trigger: String, tail: String, length: Int) {
        #expect(engine([trigger]).match(typedTail: tail)?.triggerLength == length)
    }

    @Test func decomposedTailMatchesPrecomposedTrigger() {
        #expect(engine([";caf\u{E9}"]).match(typedTail: " ;cafe\u{301}")?.triggerLength == 5)
    }
}

@Suite struct SnippetExpanding {
    @Test func plainBodyIsUnchanged() async {
        let result = await expand("Kind regards,\nMeshal")
        #expect(result == SnippetExpansion(text: "Kind regards,\nMeshal", cursorOffsetFromEnd: 0))
    }

    @Test func dateAndTimeUseLocaleAndTimeZone() async {
        let result = await expand("{date} {time}", now: Date(timeIntervalSince1970: 1_791_720_000))
        #expect(result.text == "October 11, 2026 12:00\u{202F}PM")
    }

    @Test func dateWithICUFormat() async {
        let result = await expand("{date:yyyy-MM-dd} {date: EEEE} {time:HH:mm}")
        #expect(result.text == "2026-10-11 Sunday 12:00")
    }

    @Test func clipboardIsInsertedOrEmpty() async {
        #expect(await expand("[{clipboard}]", clipboard: "copied text").text == "[copied text]")
        #expect(await expand("[{clipboard}]", clipboard: nil).text == "[]")
    }

    @Test func clipboardIsNeededOnlyForItsPlaceholder() {
        #expect(SnippetEngine.usesClipboard(Snippet(trigger: ";x", body: "Re: {clipboard}")))
        #expect(!SnippetEngine.usesClipboard(Snippet(trigger: ";x", body: "Hi {cursor} on {date}")))
    }

    @Test func cursorIsRemovedAndOffsetCounted() async {
        let result = await expand("Hi {cursor}, thanks!")
        #expect(result == SnippetExpansion(text: "Hi , thanks!", cursorOffsetFromEnd: 9))
    }

    @Test func cursorOffsetCountsGraphemesAfterSubstitution() async {
        let result = await expand("<{cursor}>{clipboard}👍🏽", clipboard: "é😀")
        #expect(result.text == "<>é😀👍🏽")
        #expect(result.cursorOffsetFromEnd == 4)
    }

    @Test func onlyFirstCursorCounts() async {
        let result = await expand("a{cursor}b{cursor}c")
        #expect(result == SnippetExpansion(text: "abc", cursorOffsetFromEnd: 2))
    }

    @Test func doubledBracesAreLiteral() async {
        let result = await expand("{{date}} is {{not}} a placeholder }}")
        #expect(result.text == "{date} is {not} a placeholder }")
    }

    @Test func unknownAndUnclosedPlaceholdersStayAsTyped() async {
        #expect(await expand("{name} and {date").text == "{name} and {date")
        #expect(await expand("{ai:}").text == "{ai:}")
    }

    @Test func aiPlaceholderReceivesTrimmedInstruction() async {
        let result = await expand("Dear {ai:  greet the reader  }!")
        #expect(result.text == "Dear <greet the reader>!")
    }

    @Test func multipleAIPlaceholdersRunConcurrentlyInOrder() async {
        let tracker = ConcurrencyTracker()
        let result = await expand("{ai: one} {ai: two} {ai: three}") { instruction in
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(instruction == "one" ? 60 : 10))
            await tracker.leave()
            return instruction.uppercased()
        }
        #expect(result.text == "ONE TWO THREE")
        #expect(await tracker.peak == 3)
    }

    @Test func cursorAfterAIPlaceholderCountsItsOutput() async {
        let result = await expand("{cursor}{ai: x}") { _ in "filled" }
        #expect(result == SnippetExpansion(text: "filled", cursorOffsetFromEnd: 6))
    }
}

private actor ConcurrencyTracker {
    private var running = 0
    private(set) var peak = 0

    func enter() {
        running += 1
        peak = max(peak, running)
    }

    func leave() { running -= 1 }
}

@Suite struct OutputCleaning {
    @Test func stripsAddedQuotes() {
        #expect(OutputCleaner.final("\"Hello there.\"", original: "hi there") == "Hello there.")
        #expect(OutputCleaner.final("  “Hello there.”\n", original: "hi there") == "Hello there.")
    }

    @Test func keepsQuotesFromTheOriginal() {
        #expect(OutputCleaner.final("\"Hello,\" she said.", original: "\"Hi,\" she said.") == "\"Hello,\" she said.")
    }

    @Test func keepsBalancedInnerQuotes() {
        #expect(OutputCleaner.final("He said \"yes\"", original: "he said yes") == "He said \"yes\"")
    }

    @Test func apostrophesDoNotCountAsQuotes() {
        #expect(OutputCleaner.final("'It's fine'", original: "its fine") == "It's fine")
        #expect(OutputCleaner.final("She said 'it's fine'", original: "she said its fine") == "She said 'it's fine'")
    }

    @Test func partialDropsLeadingWhitespaceAndQuote() {
        #expect(OutputCleaner.partial("\n\"Hel", original: "hi") == "Hel")
    }
}

@Suite struct SynonymCleaning {
    @Test func dropsOriginalDuplicatesAndEmpties() {
        let cleaned = Alternatives.cleaned(["quick", "Fast", "fast", " ", "rapid.", "swift"], original: "fast")
        #expect(cleaned == ["quick", "rapid", "swift"])
    }

    @Test func dropsSuggestionsThatGrowOrRepeatTheWord() {
        let cleaned = Alternatives.cleaned(["verify", "verify the amount", "confirm the sum", "double-check"], original: "confirm")
        #expect(cleaned == ["verify", "double-check"])
    }

    @Test func multiWordOriginalAllowsOneExtraWord() {
        let cleaned = Alternatives.cleaned(["proceed", "go ahead", "carry on with it", "push ahead now"], original: "move forward")
        #expect(cleaned == ["proceed", "go ahead", "push ahead now"])
    }

    @Test func matchesCapitalizationOfOriginal() {
        #expect(Alternatives.cleaned(["quick", "rapid"], original: "Fast") == ["Quick", "Rapid"])
    }

    @Test func capsAtEight() {
        let items = (1...12).map { "word\($0)" }
        #expect(Alternatives.cleaned(items, original: "x").count == 8)
    }
}

@Suite struct TargetLanguages {
    @Test(arguments: [("fr", "French", "fr"), ("French", "French", "fr"), ("pt-BR", "Portuguese (Brazil)", "pt-BR")])
    func resolvesCodesAndNames(input: String, name: String, code: String) {
        let target = LanguageSupport.resolveTarget(input)
        #expect(target.name == name)
        #expect(target.code == code)
    }

    @Test func unknownNamePassesThrough() {
        let target = LanguageSupport.resolveTarget("Pirate")
        #expect(target.name == "Pirate")
        #expect(target.code == nil)
    }
}
