import Testing
@testable import Inference

@Suite struct ShownSuggestionTests {
    @Test func showsTheUpdateWhenNothingShows() {
        #expect(ShownSuggestion.merge(shown: [], drawn: false, update: [" to take", " to have"], settled: false) == [" to take", " to have"])
    }

    @Test func aLongerCandidateGrowsTheShownText() {
        let merged = ShownSuggestion.merge(shown: [" to take"], drawn: true, update: [" to have a", " to take a look"], settled: false)
        #expect(merged == [" to take a look", " to have a", " to take"])
    }

    @Test func keepsTheShownTextWhileTheUserTypes() {
        let merged = ShownSuggestion.merge(shown: [" to take a"], drawn: true, update: [" to have a look"], settled: false)
        #expect(merged == [" to take a", " to have a look"])
    }

    @Test func anUpdateReplacesTextNotDrawnYet() {
        let merged = ShownSuggestion.merge(shown: [" to take a", " to take"], drawn: false, update: [" to have a look"], settled: false)
        #expect(merged == [" to have a look"])
    }

    @Test func aSettledAnswerReplacesTheShownText() {
        let merged = ShownSuggestion.merge(shown: [" to take a"], drawn: true, update: [" to have a look", " to take a look"], settled: true)
        #expect(merged == [" to have a look", " to take a look", " to take a"])
    }

    @Test func aSettledAnswerThatTheShownTextExtendsKeepsIt() {
        #expect(ShownSuggestion.merge(shown: [" to take a"], drawn: true, update: [" to take"], settled: true) == [" to take a", " to take"])
    }

    @Test func typographicQuotesStillExtend() {
        let merged = ShownSuggestion.merge(shown: [" don't"], drawn: true, update: [" don\u{2019}t know"], settled: false)
        #expect(merged.first == " don\u{2019}t know")
    }
}
