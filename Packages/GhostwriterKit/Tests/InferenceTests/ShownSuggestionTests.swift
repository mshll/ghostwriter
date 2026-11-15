import Testing
@testable import Inference

@Suite struct ShownSuggestionTests {
    @Test func showsTheUpdateWhenNothingShows() {
        #expect(ShownSuggestion.merge(shown: [], drawn: false, update: [" to take", " to have"]) == [" to take", " to have"])
    }

    @Test func aLongerCandidateGrowsTheShownText() {
        let merged = ShownSuggestion.merge(shown: [" to take"], drawn: true, update: [" to have a", " to take a look"])
        #expect(merged == [" to take a look", " to have a", " to take"])
    }

    @Test func keepsTheShownTextWhileTheUserTypes() {
        let merged = ShownSuggestion.merge(shown: [" to take a"], drawn: true, update: [" to have a look"])
        #expect(merged == [" to take a", " to have a look"])
    }

    @Test func anUpdateReplacesTextNotDrawnYet() {
        let merged = ShownSuggestion.merge(shown: [" to take a", " to take"], drawn: false, update: [" to have a look"])
        #expect(merged == [" to have a look"])
    }

    @Test func aDisagreeingAnswerKeepsTheDrawnText() {
        let merged = ShownSuggestion.merge(shown: [" to take a"], drawn: true, update: [" to have a look", " to make"])
        #expect(merged == [" to take a", " to have a look", " to make"])
    }

    @Test func anExtendingAnswerGrowsTheDrawnText() {
        let merged = ShownSuggestion.merge(shown: [" to take a"], drawn: true, update: [" to have a look", " to take a look"])
        #expect(merged == [" to take a look", " to have a look", " to take a"])
    }

    @Test func aShorterAnswerKeepsTheDrawnText() {
        #expect(ShownSuggestion.merge(shown: [" to take a"], drawn: true, update: [" to take"]) == [" to take a", " to take"])
    }

    @Test func typographicQuotesStillExtend() {
        let merged = ShownSuggestion.merge(shown: [" don't"], drawn: true, update: [" don\u{2019}t know"])
        #expect(merged.first == " don\u{2019}t know")
    }
}
