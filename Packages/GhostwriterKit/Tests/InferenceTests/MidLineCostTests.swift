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

    @Test func midLineBeamsNarrowOnlyTheMidLineSearch() async throws {
        let wide = await run(midLine { $0.midLineBeams = nil })
        let narrow = await run(midLine { $0.midLineBeams = 2 })
        #expect(narrow.total < wide.total)
        #expect(narrow.final != nil)

        var lineEnd = CompletionRequest.toy("i saw the")
        lineEnd.tuning.midLineBeams = 2
        let unchanged = await run(lineEnd)
        #expect(unchanged.largest > 2)
    }
}
