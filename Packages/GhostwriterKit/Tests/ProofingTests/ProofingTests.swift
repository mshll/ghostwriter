import Testing
@testable import Proofing

@MainActor @Suite struct LastWordChecks {
    @Test func flagsAFinishedMisspelledWord() throws {
        let typo = try #require(SpellCheck.lastWord(in: "see you tomorow ", language: "en"))
        #expect(typo.word == "tomorow")
        #expect(typo.distanceFromEnd == 1)
        #expect(typo.guesses.first == "tomorrow")
    }

    @Test func waitsUntilTheWordIsFinished() {
        #expect(SpellCheck.lastWord(in: "see you tomorow", language: "en") == nil)
    }

    @Test func ignoresCorrectWords() {
        #expect(SpellCheck.lastWord(in: "see you tomorrow ", language: "en") == nil)
    }

    @Test func checksACapitalizedWordOnlyAtASentenceStart() {
        #expect(SpellCheck.lastWord(in: "Tomorow ", language: "en")?.guesses.first == "Tomorrow")
        #expect(SpellCheck.lastWord(in: "Done. Tomorow ", language: "en") != nil)
        #expect(SpellCheck.lastWord(in: "I met Tomorow ", language: "en") == nil)
    }

    @Test func skipsAcronymsMixedCaseAndShortWords() {
        #expect(SpellCheck.lastWord(in: "use the GPU ", language: "en") == nil)
        #expect(SpellCheck.lastWord(in: "on the iPhnoe ", language: "en") == nil)
        #expect(SpellCheck.lastWord(in: "it is ot ", language: "en") == nil)
    }

    @Test func skipsHandlesTagsPathsAndDomains() {
        #expect(SpellCheck.lastWord(in: "ping @tomorow ", language: "en") == nil)
        #expect(SpellCheck.lastWord(in: "see #tomorow ", language: "en") == nil)
        #expect(SpellCheck.lastWord(in: "open src/tomorow ", language: "en") == nil)
        #expect(SpellCheck.lastWord(in: "visit tomorow.com ", language: "en") == nil)
        #expect(SpellCheck.lastWord(in: "set snake_tomorow ", language: "en") == nil)
    }

    @Test func keepsApostrophesInsideWords() {
        let tokens = SpellCheck.tokens(in: Array("don't 'quote' it’s"))
        #expect(tokens.map(\.word) == ["don't", "quote", "it’s"])
    }
}

@MainActor @Suite struct SentenceChecks {
    @Test func findsEveryTypoInTheLastSentence() {
        let typos = SpellCheck.sentence(endingAt: "Old sentnce here. I recieve teh mail tomorow.", language: "en")
        #expect(typos.map(\.word) == ["recieve", "teh", "tomorow"])
        #expect(typos.map(\.distanceFromEnd) == [18, 14, 1])
    }

    @Test func ignoresTrailingSpaceAfterTheSentenceEnd() {
        #expect(SpellCheck.sentence(endingAt: "I recieve it. ", language: "en").map(\.word) == ["recieve"])
    }
}

@Suite struct Judging {
    private let typo = Misspelling(word: "tomorow", distanceFromEnd: 1, guesses: ["tomorrow", "tomorrows"])

    @Test func offersTheGuessTheModelPrefers() async {
        let judgment = await TypoJudge().judge(typo) { ["tomorow": -14, "tomorrow": -9, "tomorrows": -12][$0] ?? -99 }
        #expect(judgment.verdict == .offer("tomorrow"))
        #expect(judgment.margin == 5)
    }

    @Test func autoFixesOnlyWithALargeMarginAndAClearWinner() async {
        let clear = await TypoJudge().judge(typo) { ["tomorow": -20, "tomorrow": -5, "tomorrows": -15][$0] ?? -99 }
        #expect(clear.verdict == .autoFix("tomorrow"))
        let close = await TypoJudge().judge(typo) { ["tomorow": -20, "tomorrow": -5, "tomorrows": -7][$0] ?? -99 }
        #expect(close.verdict == .offer("tomorrow"))
    }

    @Test func keepsAWordTheModelFindsAsLikely() async {
        let judgment = await TypoJudge().judge(typo) { ["tomorow": -6, "tomorrow": -8][$0] ?? -99 }
        #expect(judgment.verdict == .keep)
    }

    @Test func offersTheAutocorrectionTheModelRanksFirstByAnyLead() async {
        let common = Misspelling(word: "recieve", distanceFromEnd: 1, guesses: ["receive", "relieve"], correction: "receive")
        let judgment = await TypoJudge().judge(common) { ["recieve": -8, "receive": -6.5, "relieve": -11][$0] ?? -99 }
        #expect(judgment.verdict == .offer("receive"))
        let other = await TypoJudge().judge(typo) { ["tomorow": -8, "tomorrow": -6.5][$0] ?? -99 }
        #expect(other.verdict == .keep)
    }

    @Test func offersTheFirstGuessWithoutAModel() async {
        #expect(await TypoJudge().judge(typo, score: nil).verdict == .offer("tomorrow"))
    }

    @Test func keepsAWordWithoutGuesses() async {
        let none = Misspelling(word: "zxqv", distanceFromEnd: 1, guesses: [])
        #expect(await TypoJudge().judge(none, score: nil).verdict == .keep)
    }
}

@Suite struct ApplyingFixes {
    @Test func fixesSeveralWordsFromTheFirstOneOn() throws {
        let fixes = [
            TypoFix(word: "recieve", correction: "receive", distanceFromEnd: 19),
            TypoFix(word: "teh", correction: "the", distanceFromEnd: 15),
        ]
        let tail = try #require(TypoFix.tail(of: "Old. I recieve teh mail tomorrow.", applying: fixes))
        #expect(tail.original == "recieve teh mail tomorrow.")
        #expect(tail.corrected == "receive the mail tomorrow.")
    }

    @Test func handlesCorrectionsOfADifferentLength() throws {
        let fixes = [
            TypoFix(word: "alot", correction: "a lot", distanceFromEnd: 14),
            TypoFix(word: "becuse", correction: "because", distanceFromEnd: 1),
        ]
        let tail = try #require(TypoFix.tail(of: "alot of it becuse ", applying: fixes))
        #expect(tail.corrected == "a lot of it because ")
    }

    @Test func refusesWhenTheWordMoved() {
        #expect(TypoFix.tail(of: "see you tomorrow ", applying: [TypoFix(word: "tomorow", correction: "tomorrow", distanceFromEnd: 1)]) == nil)
    }

    @Test func knowsWhenTheWordEndsTheText() {
        let fix = TypoFix(word: "tomorow", correction: "tomorrow", distanceFromEnd: 2)
        #expect(fix.endsText("see you tomorow. "))
        #expect(!TypoFix(word: "teh", correction: "the", distanceFromEnd: 6).endsText("in teh mail "))
    }
}

@Suite struct ScoringContexts {
    private let text = "I recieve teh mail."
    private let recieve = Misspelling(word: "recieve", distanceFromEnd: 10, guesses: ["receive"])
    private let teh = Misspelling(word: "teh", distanceFromEnd: 6, guesses: ["the"])

    @Test func stopsBeforeTheNextTypo() {
        let context = recieve.scoringContext(in: text, next: teh, earlierFixes: [])
        #expect(context.before == "I ")
        #expect(context.after == " ")
    }

    @Test func appliesEarlierFixesBeforeTheWord() {
        let fix = TypoFix(word: "recieve", correction: "receive", distanceFromEnd: 10)
        let context = teh.scoringContext(in: text, next: nil, earlierFixes: [fix])
        #expect(context.before == "I receive ")
        #expect(context.after == " mail.")
    }
}
