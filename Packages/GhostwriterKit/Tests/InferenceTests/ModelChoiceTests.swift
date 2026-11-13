import Testing
@testable import Inference

@Suite struct ModelChoiceTests {
    private let large = ModelChoiceTests.spec("large", size: 3_000)
    private let small = ModelChoiceTests.spec("small", size: 1_000)

    private func choose(
        active: ModelSpec?, suggestionsOn: Bool = true, memoryIsCritical: Bool = false, prefersSmallest: Bool = false
    ) -> ModelChoice {
        ModelChoice.choose(
            active: active, installed: [large, small], suggestionsOn: suggestionsOn,
            memoryIsCritical: memoryIsCritical, prefersSmallest: prefersSmallest
        )
    }

    @Test func loadsTheActiveModel() {
        #expect(choose(active: large) == .load(large))
    }

    @Test func loadsTheSmallestInstalledWhenPreferred() {
        #expect(choose(active: large, prefersSmallest: true) == .load(small))
    }

    @Test func unloadsWhileSuggestionsAreOffEverywhere() {
        #expect(choose(active: large, suggestionsOn: false) == .unloadWhileOff)
        #expect(choose(active: large, suggestionsOn: false, prefersSmallest: true) == .unloadWhileOff)
        #expect(choose(active: large, suggestionsOn: false).model == nil)
    }

    @Test func offTakesPrecedenceOverLowMemory() {
        #expect(choose(active: large, suggestionsOn: false, memoryIsCritical: true) == .unloadWhileOff)
    }

    @Test func unloadsWhenMemoryIsCritical() {
        #expect(choose(active: large, memoryIsCritical: true) == .unloadForMemory)
        #expect(choose(active: large, memoryIsCritical: true).model == nil)
    }

    @Test func nothingToLoadWithoutAnActiveModel() {
        #expect(choose(active: nil) == .noModel)
        #expect(choose(active: nil, suggestionsOn: false) == .noModel)
        #expect(choose(active: nil, memoryIsCritical: true) == .noModel)
    }

    @Test func turningSuggestionsBackOnLoadsAgain() {
        #expect(choose(active: large, suggestionsOn: false).model == nil)
        #expect(choose(active: large, suggestionsOn: true).model == large)
    }

    private static func spec(_ id: String, size: Int64) -> ModelSpec {
        ModelSpec(
            id: id, displayName: id, family: .custom, repo: "", fileName: "\(id).gguf", sizeBytes: size, sha256: nil,
            minMemoryGB: 8, minTier: 0
        )
    }
}
