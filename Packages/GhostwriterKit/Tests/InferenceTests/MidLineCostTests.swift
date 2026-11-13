import Testing
@testable import Inference

@Suite struct MidLineCostTests {
    private struct Run {
        var updates: [SuggestionUpdate] = []
        /// Decode sizes of the units after the one that decodes the prompt, without the unit that publishes the final update.
        var stepDecodes: [Int] = []
        var largest: Int { stepDecodes.max() ?? 0 }
        var total: Int { stepDecodes.reduce(0, +) }
        var final: [Candidate]? { updates.last?.isFinal == true ? updates.last?.candidates : nil }
    }

    private func run(_ request: CompletionRequest) async -> Run {
        let toy = await ToyEngine.make()
        let subscription = toy.engine.suggestions(for: request)
        var result = Run()
        var seen = toy.context.decodeSizes.count
        var units = 0
        while let unit = await toy.engine.runUnit() {
            units += 1
            let mine = unit.publications.filter { $0.request == subscription.id }.map(\.update)
            result.updates += mine
            let sizes = Array(toy.context.decodeSizes[seen...])
            seen = toy.context.decodeSizes.count
            if units > 1, !mine.contains(where: \.isFinal) { result.stepDecodes += sizes }
        }
        return result
    }

    private func midLine(_ change: (inout SearchTuning) -> Void = { _ in }) -> CompletionRequest {
        var request = CompletionRequest.toy("i saw the", after: " over the lazy dog.")
        change(&request.tuning)
        return request
    }

    @Test func fittingKeepsTheSequencesThatFitInOrder() {
        let sequences: [[Int32]] = [[1, 2, 3], [4, 5, 6, 7, 8], [9], [10, 11]]
        let tight: [[Int32]] = Scheduler.fitting(sequences, room: 3)
        let none: [[Int32]] = Scheduler.fitting(sequences, room: 0)
        let all: [[Int32]] = Scheduler.fitting(sequences, room: 100)
        #expect(tight == [sequences[0], sequences[2], sequences[3]])
        #expect(none == [sequences[2]])
        #expect(all == sequences)
    }

    @Test func midLineBeamsNarrowOnlyTheMidLineSearch() async throws {
        let narrow = await run(midLine { $0.midLineBeams = 2; $0.midLineRerankInterval = 0 })
        #expect(narrow.largest <= 2)
        #expect(narrow.final != nil)

        var lineEnd = CompletionRequest.toy("i saw the")
        lineEnd.tuning.midLineBeams = 2
        let wide = await run(lineEnd)
        #expect(wide.largest > 2)
    }

    @Test func rerankingOnlyAtTheEndShowsOnlyTheFinalCandidates() async throws {
        let streamed = await run(midLine())
        let atEnd = await run(midLine { $0.midLineRerankInterval = 0 })
        let shownEarly = atEnd.updates.filter { !$0.isFinal && !$0.candidates.isEmpty }
        #expect(shownEarly.isEmpty)
        #expect(atEnd.final != nil)
        #expect(atEnd.final == streamed.final)
        #expect(atEnd.total < streamed.total)
    }

    @Test func rerankingEveryOtherStepSkipsTheOddSteps() async throws {
        let every = await run(midLine())
        let other = await run(midLine { $0.midLineRerankInterval = 2 })
        #expect(other.total < every.total)
        #expect(other.final == every.final)
    }

    @Test func aDecodeBudgetCapsEachStep() async throws {
        let unbounded = await run(midLine())
        #expect(unbounded.largest > 8)
        let bounded = await run(midLine { $0.midLineDecodeBudget = 8 })
        #expect(bounded.largest <= 8)
        #expect(bounded.final == unbounded.final)
    }
}
