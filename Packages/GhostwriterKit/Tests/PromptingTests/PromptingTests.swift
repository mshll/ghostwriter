import Foundation
import GWCore
import Testing
@testable import Prompting

struct QuarterCounter: TokenCounting {
    func countTokens(_ text: String) -> Int { (text.count + 3) / 4 }
}

let sundayAfternoon = Date(timeIntervalSince1970: 1_791_733_920)

func makeBuilder(_ budgets: PromptBudgets = PromptBudgets()) -> PromptBuilder {
    var builder = PromptBuilder(counter: QuarterCounter(), budgets: budgets)
    builder.timeZone = .gmt
    return builder
}

let englishParagraph = """
    Thank you for sending the draft over. I read through the proposal and I think the structure works well, \
    although the second section could use a few more concrete examples to support the main argument
    """

@Suite struct Layout {
    @Test func sectionsRunFromStableToVolatile() throws {
        let context = PromptContext(
            instructions: "Keep it short.", userName: "Sam", appName: "Mail", fieldKind: .email,
            now: sundayAfternoon, examples: ["An earlier passage I wrote about budgets."],
            clipboard: "Copied text", screenText: "Screen text", textBefore: englishParagraph,
            textAfter: " and more after"
        )
        let text = makeBuilder().build(context).text
        let markers = [
            PromptText.preamble, PromptText.instructionsLabel, "My name is Sam.", "I am typing in Mail.",
            "I am writing an email.", PromptText.examplesLabel, PromptText.clipboardLabel, PromptText.screenLabel,
            PromptText.afterLabel, "I am writing in English.", "It is Sunday", PromptText.typingMidLineLabel,
        ]
        let offsets = try markers.map { marker in
            try #require(text.range(of: marker)?.lowerBound, "missing \(marker)")
        }
        #expect(offsets == offsets.sorted())
        #expect(text.hasPrefix(PromptText.preamble))
        #expect(text.hasSuffix("support the main "))
    }

    @Test func dateLineLeavesTheContextPrefixUnchanged() throws {
        var context = PromptContext(
            appName: "Mail", now: sundayAfternoon, examples: ["An earlier passage I wrote about budgets."],
            clipboard: "Copied text", screenText: "Screen text", textBefore: englishParagraph
        )
        let plain = makeBuilder().build(context)
        context.keepsDate = true
        let dated = makeBuilder().build(context)
        #expect(!plain.includesDate && dated.includesDate)
        let screenEnd = try #require(plain.text.range(of: "Screen text")?.upperBound)
        #expect(dated.text.hasPrefix(plain.text[..<screenEnd]))
    }

    @Test func emptySectionsAreOmittedWithTheirLabels() {
        let text = makeBuilder().build(PromptContext(appName: "Notes", textBefore: "Hello there ")).text
        #expect(text == PromptText.preamble + "I am typing in Notes.\n\n" + PromptText.typingLabel + "Hello there ")
    }

    @Test func identicalInputsGiveIdenticalBytes() {
        let context = PromptContext(
            appName: "Mail", fieldKind: .email, now: sundayAfternoon, examples: ["One", "Two"],
            clipboard: "clip", screenText: String(repeating: "Screen words here. ", count: 300),
            textBefore: englishParagraph, textAfter: "rest"
        )
        #expect(makeBuilder().build(context) == makeBuilder().build(context))
    }

    @Test func prefixStaysByteStableWhileTextBeforeGrows() {
        var budgets = PromptBudgets()
        budgets.before = 24
        let screen = String(repeating: "A line of screen text near the caret. ", count: 120)
        func prompt(_ before: String) -> String {
            makeBuilder(budgets).build(PromptContext(
                appName: "Pages", examples: ["A passage I wrote some time ago about the proposal."],
                clipboard: "copied", screenText: screen, textBefore: before
            )).text
        }
        let short = prompt(englishParagraph)
        let long = prompt(englishParagraph + " and I would also like to add")
        let prefix = String(short[..<(short.range(of: PromptText.typingLabel)?.upperBound ?? short.endIndex)])
        #expect(prefix.hasSuffix(PromptText.typingLabel))
        #expect(long.hasPrefix(prefix))
        #expect(long.hasSuffix("would also like to "))
    }

    @Test func windowTitleMatchingAppNameIsSkipped() {
        let text = makeBuilder().build(PromptContext(appName: "Notes", windowTitle: "notes", textBefore: "Hi ")).text
        #expect(!text.contains("The window is titled"))
    }

    @Test func longEnvironmentValuesAreClipped() {
        let title = String(repeating: "x", count: 150)
        let text = makeBuilder().build(PromptContext(appName: "Safari", windowTitle: title, textBefore: "Hi ")).text
        #expect(text.contains("The window is titled \"\(String(repeating: "x", count: 99))⋯\"."))
    }

    @Test func languageLineNamesTheDetectedLanguage() {
        let built = makeBuilder().build(PromptContext(
            appName: "Notes",
            textBefore: "Vielen Dank für deine Nachricht, ich habe mich sehr darüber gefreut und melde mich bald "
        ))
        #expect(built.language == "de")
        #expect(built.text.contains("I am writing in German."))
    }

    @Test func examplesAreTakenWholeUntilTheBudgetIsFull() {
        var budgets = PromptBudgets()
        budgets.examples = 40
        let examples = (1...3).map { "Example \($0) " + String(repeating: "z", count: 90) }
        let text = makeBuilder(budgets).build(PromptContext(appName: "Notes", examples: examples, textBefore: "Hi ")).text
        #expect(text.contains(examples[0]))
        #expect(!text.contains("Example 2"))
        #expect(!text.contains("Example 3"))
    }

    @Test func draftModeKeepsMoreTextBeforeTheCaret() {
        let before = String(repeating: "This sentence repeats to fill the field. ", count: 120)
        let builder = makeBuilder()
        let inline = builder.build(PromptContext(appName: "Notes", textBefore: before))
        let draft = builder.build(PromptContext(appName: "Notes", textBefore: before, mode: .draft))
        #expect(draft.text.count > inline.text.count + 2_000)
    }
}

@Suite struct StopStrings {
    func stops(_ completion: String) -> Bool {
        BuiltPrompt.stopStrings.contains { completion.contains($0) }
    }

    @Test func echoedPromptTextStops() {
        for label in PromptText.labels { #expect(stops("Fine.\n\n" + label + "More")) }
        #expect(stops("Fine." + PromptText.exampleSeparator + "Another passage"))
        #expect(stops("Fine.\n\n" + PromptText.preamble))
        let prompt = makeBuilder().build(PromptContext(
            appName: "Notes", windowTitle: "Plans", fieldLabel: "Subject", textBefore: "Hi "
        )).text
        for line in ["The window is titled \"Plans\".", "The field is labeled \"Subject\"."] {
            #expect(prompt.contains("\n" + line))
            #expect(stops("Fine.\n" + line))
        }
    }

    @Test func echoedEnvironmentLinesStop() {
        let context = PromptContext(appName: "Mail", fieldKind: .email, textBefore: "See you on Thursday at the meeting with the whole team. ")
        let prompt = makeBuilder().build(context).text
        for line in ["I am typing in Mail.", "I am writing an email.", "I am writing in English."] {
            #expect(prompt.contains("\n" + line))
            #expect(stops("Fine.\n" + line))
        }
        #expect(stops("Fine.\nIt is Wednesday, October 14, 2026, around"))
        #expect(stops("Fine.\nI am typing on my Mac.\nI am writing a"))
        #expect(stops("Fine.\nI am typing on my phone. My text comes last; before it is"))
    }

    @Test(arguments: [
        "| Name | Count |\n|---|---|\n| a | 1 |",
        "Thanks.\nI am writing in response to your email.",
        "Thanks.\nIt is a pleasure to meet you.",
        "Thanks.\nMy name is Sam.",
        "---\ntitle: Notes\n---\nBody",
        "Heading\n---\nText",
        "wait---what",
        "The window is titled \"Plans\" in my draft.",
    ])
    func markdownYamlAndProseDoNotStop(_ completion: String) {
        #expect(!stops(completion))
    }
}

@Suite struct MidLine {
    let textAfter = " world, how are you?\nSecond line\nThird line"

    @Test func textAfterGetsItsOwnSectionAndTheMidLineLabel() {
        let text = makeBuilder().build(PromptContext(appName: "Notes", textBefore: "Hello ", textAfter: textAfter)).text
        #expect(text.contains(PromptText.afterLabel + "world, how are you?\nSecond line\n\n"))
        #expect(!text.contains("Third line"))
        #expect(text.hasSuffix(PromptText.typingMidLineLabel + "Hello "))
    }

    @Test func turningTheOptionOffDropsTheSection() {
        var builder = makeBuilder()
        builder.includeAfterText = false
        let text = builder.build(PromptContext(appName: "Notes", textBefore: "Hello ", textAfter: textAfter)).text
        #expect(!text.contains(PromptText.afterLabel))
        #expect(text.hasSuffix(PromptText.typingLabel + "Hello "))
    }

    @Test func caretAtLineEndIsNotMidLine() {
        let text = makeBuilder().build(PromptContext(appName: "Notes", textBefore: "Hello ", textAfter: "  \nNext")).text
        #expect(!text.contains(PromptText.afterLabel))
    }

    @Test func draftModeHasNoAfterSection() {
        let text = makeBuilder().build(PromptContext(appName: "Notes", textBefore: "Hello ", textAfter: textAfter, mode: .draft)).text
        #expect(!text.contains(PromptText.afterLabel))
    }
}

@Suite struct Budgets {
    @Test func grantsRoundUpToTheStepAndStopAtDemand() {
        let granted = BudgetAllocator.allocate(
            demands: [350, 200, 500, 500, 300], priorities: [0, 0, 1, 1, 2], total: 1_200, step: 32
        )
        #expect(granted == [350, 200, 352, 352, 0])
    }

    @Test func waterFillGivesSmallDemandsInFullAndSplitsTheRest() {
        #expect(BudgetAllocator.allocate(demands: [100, 900], priorities: [1, 1], total: 600, step: 32) == [100, 512])
    }

    @Test func higherPriorityIsFilledFirst() {
        #expect(BudgetAllocator.allocate(demands: [300, 300], priorities: [0, 1], total: 400, step: 32) == [300, 128])
    }

    @Test func enoughBudgetMeetsEveryDemand() {
        #expect(BudgetAllocator.allocate(demands: [10, 0, 45], priorities: [0, 1, 2], total: 5_000, step: 32) == [10, 0, 45])
    }
}

@Suite struct Truncation {
    let fitter = SectionFitter(counter: QuarterCounter())

    @Test func textThatFitsIsKeptWhole() {
        #expect(fitter.fit("Short text."[...], budget: 10, keep: .end) == "Short text.")
    }

    @Test func keepingTheEndCutsAtASentenceStart() {
        let text = "First sentence is here. Second sentence is longer than the first. Third one ends it."
        #expect(fitter.fit(text[...], budget: 16, keep: .end) == "Second sentence is longer than the first. Third one ends it.")
    }

    @Test func keepingTheStartPrefersAParagraphOverASentence() {
        let paragraph = "The quick brown fox jumps over the lazy dog every day ok"
        let text = paragraph + "\nHi. There is more text after this point for sure."
        #expect(fitter.fit(text[...], budget: 16, keep: .start) == paragraph)
    }

    @Test func keepingTheStartCutsAtAWordWhenNoSentenceEnds() {
        let text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho"
        let kept = fitter.fit(text[...], budget: 10, keep: .start)
        #expect(text.hasPrefix(kept))
        #expect(kept.last?.isLetter == true)
        #expect(text[text.index(text.startIndex, offsetBy: kept.count)] == " ")
        #expect(QuarterCounter().countTokens(kept) >= 9)
    }

    @Test func hardCutsCarryTheMarker() {
        let text = String(repeating: "abcdefghij", count: 20)
        let end = fitter.fit(text[...], budget: 10, keep: .end)
        #expect(end == "⋯" + text.suffix(39))
        let start = fitter.fit(text[...], budget: 10, keep: .start)
        #expect(start == text.prefix(39) + "⋯")
    }

    @Test func veryLongTextIsCutWithoutCountingAllOfIt() {
        let text = String(repeating: "word ", count: 20_000) + "the end."
        let kept = fitter.fit(text[...], budget: 50, keep: .end)
        #expect(kept.hasSuffix("the end."))
        #expect(QuarterCounter().countTokens(kept) <= 50)
    }
}

@Suite struct PartialWords {
    @Test(arguments: [
        ("Thanks for the upd", "Thanks for the ", "upd"),
        ("Viele Grüße und schö", "Viele Grüße und ", "schö"),
        ("شكرا على المساعد", "شكرا على ", "المساعد"),
        ("ありがとうございま", "ありがとうございま", ""),
        ("東京tow", "東京", "tow"),
        ("Hello ", "Hello ", ""),
        ("I don'", "I ", "don'"),
        ("She said 'hel", "She said '", "hel"),
        ("Done.", "Done.", ""),
    ])
    func trailingWordIsSplitOff(text: String, head: String, partial: String) {
        let split = PartialWord.split(text)
        #expect(String(split.head) == head)
        #expect(String(split.partial) == partial)
    }

    @Test func promptEndsBeforeThePartialWord() {
        let built = makeBuilder().build(PromptContext(appName: "Notes", textBefore: "Thanks for the upd"))
        #expect(built.partialWord == "upd")
        #expect(built.text.hasSuffix(PromptText.typingLabel + "Thanks for the "))
    }

    /// Rich text editors keep a space typed at the end as a no-break space until the next character.
    @Test(arguments: [
        ("A\u{00A0}b. Thanks for the\u{00A0}", "A\u{00A0}b. Thanks for the ", ""),
        ("Thanks for the \u{00A0}upd", "Thanks for the  ", "upd"),
    ])
    func trailingNoBreakSpacesEndThePromptAsSpaces(text: String, prompt: String, partial: String) {
        let built = makeBuilder().build(PromptContext(appName: "Notes", textBefore: text))
        #expect(built.partialWord == partial)
        #expect(built.text.hasSuffix(PromptText.typingLabel + prompt))
    }
}

@Suite struct DateLine {
    @Test(arguments: [
        ("Let me know what you think", FieldKind.email, true),
        ("Let me know what you think", .chat, true),
        ("Let me know what you think", .unknown, false),
        ("Can we meet tomorrow", .unknown, true),
        ("Shall we say next week", .document, true),
        ("Call me at 3pm", .unknown, true),
        ("Call me at 3 pm", .unknown, true),
        ("Nos vemos el lunes", .unknown, true),
        ("Treffen wir uns um 15:30", .unknown, true),
        ("Bis morgen", .unknown, true),
        ("On se voit demain", .unknown, true),
        ("On se voit aujourd’hui", .unknown, true),
        ("نلتقي غداً", .unknown, true),
        ("نراك يوم الخميس", .unknown, true),
        ("سأخبرك بالأمس", .unknown, true),
        ("The quick brown fox", .unknown, false),
        ("I may be late", .unknown, false),
    ])
    func dateAppearsOnlyWhenRelevant(text: String, kind: FieldKind, expected: Bool) {
        let prompt = makeBuilder().build(PromptContext(appName: "App", fieldKind: kind, now: sundayAfternoon, textBefore: text)).text
        #expect(prompt.contains("It is Sunday, October 11, 2026, around 3:45 PM.") == expected)
    }

    @Test func wordsAreMatchedInTheDetectedLanguageOnly() {
        #expect(!TemporalCues.mentionsTime("Ich bin schon hier", language: "de"))
        #expect(TemporalCues.mentionsTime("Je suis arrivé hier", language: "fr"))
        #expect(TemporalCues.mentionsTime("Ich bin schon hier", language: nil))
    }

    @Test func onlyTheTextNearTheCaretCounts() {
        let text = "See you tomorrow. " + String(repeating: "Unrelated words here. ", count: 20)
        #expect(!TemporalCues.isRelevant(fieldKind: .unknown, textBefore: text, language: "en"))
    }

    @Test func keptDateSurvivesTheTimeWordScrollingAway() {
        let text = "See you tomorrow. " + String(repeating: "Unrelated words here. ", count: 20)
        let builder = makeBuilder()
        let dropped = builder.build(PromptContext(appName: "App", now: sundayAfternoon, textBefore: text))
        let kept = builder.build(PromptContext(appName: "App", now: sundayAfternoon, textBefore: text, keepsDate: true))
        #expect(!dropped.includesDate && !dropped.text.contains("It is Sunday"))
        #expect(kept.includesDate && kept.text.contains("It is Sunday, October 11, 2026, around 3:45 PM."))
    }

    @Test func timeRoundsDownToTheQuarterHour() {
        #expect(EnvironmentLines.dateLine(sundayAfternoon, timeZone: .gmt) == "It is Sunday, October 11, 2026, around 3:45 PM.")
        let justAfterMidnight = Date(timeIntervalSince1970: 1_791_677_220)
        #expect(EnvironmentLines.dateLine(justAfterMidnight, timeZone: .gmt) == "It is Sunday, October 11, 2026, around 12:00 AM.")
    }
}

@Suite struct Languages {
    @Test func shortTextIsUndetermined() {
        #expect(LanguageDetector.dominantLanguage(of: "Hi there") == nil)
    }

    @Test func englishProseIsDetected() {
        #expect(LanguageDetector.dominantLanguage(of: englishParagraph) == "en")
    }

    @Test func languageNamesAreEnglish() {
        #expect(LanguageDetector.englishName(of: "de") == "German")
        #expect(LanguageDetector.englishName(of: "ar") == "Arabic")
    }
}

struct WordPieceCounter: TokenCounting {
    func countTokens(_ text: String) -> Int {
        var tokens = 0
        var run = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
                if run % 4 == 0 { tokens += 1 }
                run += 1
            } else {
                run = 0
                if scalar != " " { tokens += 1 }
            }
        }
        return tokens
    }
}

@Suite struct Performance {
    #if DEBUG
    static let optimized = false
    #else
    static let optimized = true
    #endif

    @Test(.enabled(if: optimized)) func buildStaysWellUnderTwoMilliseconds() {
        let sentence = "We should review the budget figures before the meeting and agree on next steps. "
        let context = PromptContext(
            instructions: "Write in a friendly, concise voice.", userName: "Sam", appName: "Mail",
            windowTitle: "Re: Quarterly review", fieldKind: .email, now: sundayAfternoon,
            examples: (1...3).map { "Passage \($0): " + String(repeating: sentence, count: 5) },
            clipboard: String(repeating: sentence, count: 4),
            screenText: String(repeating: sentence, count: 12),
            textBefore: String(repeating: sentence, count: 18) + "Thanks for the upd",
            textAfter: " and the rest of the line"
        )
        var builder = PromptBuilder(counter: WordPieceCounter())
        builder.timeZone = .gmt
        _ = builder.build(context)
        let clock = ContinuousClock()
        let runs = 200
        let elapsed = clock.measure { for _ in 0..<runs { _ = builder.build(context) } }
        #expect(elapsed / runs < .milliseconds(2))
    }
}
