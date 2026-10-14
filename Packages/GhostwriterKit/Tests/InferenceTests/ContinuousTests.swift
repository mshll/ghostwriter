import Foundation
import Synchronization
import Testing
@testable import Inference

@Suite struct ContinuousSuggestionTests {
    private func final(_ updates: [SuggestionUpdate]) throws -> SuggestionUpdate {
        let last = try #require(updates.last)
        #expect(last.isFinal)
        return last
    }

    @Test func freshSearchFindsThePhrase() async throws {
        let toy = await ToyEngine.make()
        let result = try final(await toy.settle(.toy("i saw the")))
        #expect(result.candidates.first?.text == " quick brown fox jumps")
        #expect(!result.reused)
    }

    @Test func typedTextFollowsTheBeamsWithoutDecoding() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the "))
        let decodes = toy.context.decodeCalls
        for text in ["i saw the q", "i saw the qu", "i saw the quic"] {
            let result = try final(await toy.settle(.toy(text)))
            #expect(result.reused)
            #expect(result.candidates.first.map { (text + $0.text).hasSuffix("quick brown fox jumps") } == true)
        }
        #expect(toy.context.decodeCalls == decodes)
    }

    /// Following filters the earlier search, so it is not always identical to a new one: it keeps the best
    /// path with the same score, may hold extra low-ranked phrases the earlier, longer search finished, and
    /// may lack paths the earlier search pruned. Shared candidates score the same.
    @Test func followedCandidatesMatchAFreshSearch() async throws {
        let followed = await ToyEngine.make()
        _ = await followed.settle(.toy("i saw the"))
        let reused = try final(await followed.settle(.toy("i saw the l")))
        let fresh = try final(await ToyEngine.make().settle(.toy("i saw the l")))
        #expect(reused.reused)
        #expect(reused.candidates.first == fresh.candidates.first)
        let freshScores = Dictionary(fresh.candidates.map { ($0.text, $0.score) }, uniquingKeysWith: max)
        for candidate in reused.candidates {
            if let score = freshScores[candidate.text] { #expect(abs(score - candidate.score) < 1e-9) }
        }
        #expect(reused.candidates.map(\.text) == ["azy dog.", "azy dog and then"])
    }

    @Test func divergentTextStartsANewSearch() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the"))
        let decodes = toy.context.decodeCalls
        let result = try final(await toy.settle(.toy("i saw the c")))
        #expect(!result.reused)
        #expect(result.candidates.first?.text == "at sat on the")
        #expect(toy.context.decodeCalls > decodes)
    }

    @Test func deletingRestartsFromTheCachedPrompt() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the qu"))
        let prompt = toy.context.sequences[0]
        let result = try final(await toy.settle(.toy("i saw the q")))
        #expect(!result.reused)
        #expect(result.candidates.first?.text == "uick brown fox jumps")
        #expect(toy.context.sequences[0] == prompt)
    }

    @Test func acceptingAWordRevivesParkedPhrases() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the"))
        let accepted = try final(await toy.settle(.toy("i saw the quick")))
        #expect(accepted.reused)
        #expect(accepted.candidates.first?.text == " brown fox jumps over")
        let fresh = try final(await ToyEngine.make().settle(.toy("i saw the quick")))
        #expect(fresh.candidates.first == accepted.candidates.first)

        let next = try final(await toy.settle(.toy("i saw the quick brown fox ")))
        #expect(next.reused)
        #expect(next.candidates.first?.text == "jumps over the quick")
    }

    @Test func anotherFieldStartsOverAndFreesTheBeams() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the"))
        let result = try final(await toy.settle(.toy("a cat")))
        #expect(!result.reused)
        #expect(result.candidates.first?.text == " sat on the quick")
        await toy.engine.clearCache()
        #expect(toy.context.busySequences == 0)
    }

    @Test func cancelEndsTheStreamButKeepsTheSearch() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the"))
        let subscription = toy.engine.suggestions(for: .toy("i saw the c"))
        _ = await toy.engine.runUnit()
        toy.engine.cancel()
        while await toy.engine.runUnit() != nil {}
        for await _ in subscription.updates {}
        let result = try final(await toy.settle(.toy("i saw the ca")))
        #expect(result.candidates.first?.text == "t sat on the")
    }

    @Test func newerRequestEndsTheOlderStream() async throws {
        let toy = await ToyEngine.make()
        let older = toy.engine.suggestions(for: .toy("i saw the"))
        let newer = toy.engine.suggestions(for: .toy("i saw a"))
        while await toy.engine.runUnit() != nil {}
        var olderUpdates = 0
        for await _ in older.updates { olderUpdates += 1 }
        #expect(olderUpdates == 0)
        var last: SuggestionUpdate?
        for await update in newer.updates { last = update }
        #expect(last?.candidates.first?.text == " red car.")
    }

    @Test func midLineFollowsAndReranks() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the", after: " over the lazy dog."))
        let tokens = toy.context.decodedTokens
        let result = try final(await toy.settle(.toy("i saw the q", after: " over the lazy dog.")))
        #expect(result.reused)
        let best = try #require(result.candidates.first)
        #expect(best.text.hasPrefix("uick"))
        #expect(!TextRules.clashes(insertion: best.text, before: " over the lazy dog."))

        let fresh = await ToyEngine.make()
        let freshResult = try final(await fresh.settle(.toy("i saw the q", after: " over the lazy dog.")))
        #expect(freshResult.candidates.first == best)
        #expect(toy.context.decodedTokens - tokens < fresh.context.decodedTokens)
    }

    private func rerankKeeps(_ text: String, for request: CompletionRequest) throws -> Bool {
        let language = ToyLanguage()
        let session = Session(
            vocabulary: language.vocabulary(), context: FakeContext(language: language), maxBeams: CompletionEngine.maxBeams,
            sequences: CompletionEngine.sequenceCount, rowSlots: BeamSearch.parkLimit
        )
        var stats = GenerationStats()
        let prompt = session.prepare(prompt: request.prompt, partialWord: request.partialWord, stats: &stats)
        try session.prefill(prompt.tokens, abort: AbortSignal(), stats: &stats)
        var totals: [[Int32]: Double] = [:]
        let kept = try session.rerankMidLine(
            [Candidate(text: text, score: 0)], required: prompt.required, textAfter: request.textAfter, tuning: request.tuning,
            totals: &totals
        )
        return !kept.isEmpty
    }

    @Test func midLineStreamsOnlyWhatTheRerankKeeps() async throws {
        let toy = await ToyEngine.make()
        let request = CompletionRequest.toy("i saw the", after: " over the lazy dog.")
        let subscription = toy.engine.suggestions(for: request)
        var updates: [SuggestionUpdate] = []
        var units = 0
        var firstShown: Int?
        while let unit = await toy.engine.runUnit() {
            units += 1
            let mine = unit.publications.filter { $0.request == subscription.id }.map(\.update)
            if firstShown == nil, mine.contains(where: { !$0.candidates.isEmpty }) { firstShown = units }
            updates += mine
        }
        #expect(try #require(firstShown) < units)
        #expect(updates.contains { !$0.isFinal })
        for candidate in updates.flatMap(\.candidates) {
            #expect(try rerankKeeps(candidate.text, for: request), "\(candidate.text)")
        }

        let fresh = await ToyEngine.make()
        let oneShot = await fresh.settle(.toy("i saw the", after: " over the lazy dog.", reuses: false))
        #expect(oneShot.count == 1)
        #expect(try final(updates).candidates.first == oneShot.first?.candidates.first)
    }

    @Test func typingMidLineShowsTheFollowedCandidateWithinAUnit() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the", after: " over the lazy dog."))
        let subscription = toy.engine.suggestions(for: .toy("i saw the q", after: " over the lazy dog."))
        let unit = try #require(await toy.engine.runUnit())
        let update = try #require(unit.publications.first { $0.request == subscription.id }?.update)
        #expect(update.reused)
        #expect(update.candidates.first?.text.hasPrefix("uick") == true)
    }

    @Test func aSearchThatRunsOutOfSequencesFreesWhatItTook() async throws {
        // Sequence 0, two free ones and the staging sequence: six beams cannot all get one.
        let toy = await ToyEngine.make(sequences: 4)
        _ = await toy.settle(.toy("i saw the "))
        #expect(toy.context.busySequences == 0)
        _ = await toy.settle(.toy("i saw the q"))
        #expect(toy.context.busySequences == 0)
    }

    private func runUntilStaged(_ toy: ToyEngine) async -> Bool {
        for _ in 0..<10_000 {
            if let unit = await toy.engine.runUnit() {
                if unit.staged { return true }
            } else {
                await Task.yield()
            }
        }
        return false
    }

    @Test func aStagedPromptIsTakenOverWithoutDecodingItAgain() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the "))
        let staged = Task { await toy.engine.stage(prompt: "a cat sat on the") }
        #expect(await runUntilStaged(toy))
        #expect(await staged.value)

        let tokens = toy.context.decodedTokens
        let result = try final(await toy.settle(.toy("a cat sat on the ")))
        let fresh = await ToyEngine.make()
        let freshResult = try final(await fresh.settle(.toy("a cat sat on the ")))
        #expect(result.candidates.first == freshResult.candidates.first)
        // The prompt came from the staging sequence: only beam steps were decoded.
        #expect(toy.context.decodedTokens - tokens < fresh.context.decodedTokens - 5)
    }

    @Test func requestsOnTheOldPromptGoFirstWhileAPromptIsStaged() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the "))
        let staged = Task { await toy.engine.stage(prompt: String(repeating: "a cat sat on the mat and then ", count: 40)) }
        while await toy.engine.runUnit() == nil { await Task.yield() }
        let subscription = toy.engine.suggestions(for: .toy("i saw the q"))
        let unit = try #require(await toy.engine.runUnit())
        let update = try #require(unit.publications.first { $0.request == subscription.id }?.update)
        #expect(update.reused)
        #expect(!unit.staged)
        #expect(await runUntilStaged(toy))
        #expect(await staged.value)
        let followed = try final(await toy.settle(.toy("i saw the qu")))
        #expect(followed.reused)
    }

    @Test func draftStreamsTextThatOnlyGrows() async throws {
        let toy = await ToyEngine.make()
        let partials = Mutex<[String]>([])
        let candidates = try await toy.engine.complete(CompletionRequest(prompt: "i saw the", maxWords: 40, mode: .draft, beams: 2)) { text in
            partials.withLock { $0.append(text) }
        }
        let streamed = partials.withLock { $0 }
        #expect(streamed.count > 1)
        for (earlier, later) in zip(streamed, streamed.dropFirst()) {
            #expect(later.hasPrefix(earlier) && later.count > earlier.count, "\(earlier) -> \(later)")
        }
        let last = try #require(streamed.last)
        #expect(candidates.first?.text.hasPrefix(last) == true)
    }

    @Test func aNewSearchShowsItsPhraseAsItGrows() async throws {
        let toy = await ToyEngine.make()
        let updates = await toy.settle(.toy("i saw the "))
        let first = try #require(updates.first?.candidates.first)
        let last = try #require(updates.last)
        #expect(updates.count > 1)
        #expect(updates.first?.isFinal == false)
        #expect(last.isFinal)
        #expect(last.candidates.first?.text.hasPrefix(first.text) == true)
        #expect(TextRules.hasWordCharacter(first.text))
    }

    @Test func automaticSteppingStreamsToTheFinalUpdate() async throws {
        let toy = await ToyEngine.make(stepping: .automatic)
        var last: SuggestionUpdate?
        for await update in toy.engine.suggestions(for: .toy("i saw the ")).updates { last = update }
        #expect(last?.isFinal == true)
        #expect(last?.candidates.first?.text == "quick brown fox jumps")
        var followed: SuggestionUpdate?
        for await update in toy.engine.suggestions(for: .toy("i saw the qu")).updates { followed = update }
        #expect(followed?.reused == true)
        #expect(followed?.candidates.first?.text == "ick brown fox jumps")
    }

    @Test func freshSearchesForEveryChangeWhenReuseIsOff() async throws {
        let toy = await ToyEngine.make()
        _ = await toy.settle(.toy("i saw the", reuses: false))
        let decodes = toy.context.decodeCalls
        let result = try final(await toy.settle(.toy("i saw the q", reuses: false)))
        #expect(!result.reused)
        #expect(result.candidates.first?.text == "uick brown fox jumps")
        #expect(toy.context.decodeCalls > decodes)
    }

    @Test func narrowedSearchKeepsWorking() async throws {
        let toy = await ToyEngine.make()
        var request = CompletionRequest.toy("i saw the")
        request.tuning.narrowAfterSteps = 2
        _ = await toy.settle(request)
        for text in ["i saw the q", "i saw the quick ", "i saw the quick brown fox jumps "] {
            var next = CompletionRequest.toy(text)
            next.tuning.narrowAfterSteps = 2
            let result = try final(await toy.settle(next))
            #expect(result.candidates.first.map { TextRules.hasWordCharacter($0.text) } == true)
        }
    }

    /// A lone space token satisfies the typed space, and the model, which rarely sees one before a word, then
    /// writes the word with its own space. The user would get two spaces.
    @Test(arguments: [false, true]) func aTypedSpaceIsNeverDoubled(followed: Bool) async throws {
        let toy = await ToyEngine.make()
        if followed { _ = await toy.settle(.toy("she")) }
        let result = try final(await toy.settle(.toy("she ")))
        #expect(result.reused == followed)
        #expect(!result.candidates.isEmpty)
        #expect(result.candidates.allSatisfy { $0.text.first?.isWhitespace == false })
        #expect(result.candidates.first?.text == "said hi.")
    }

    @Test func spacesTypedAfterTextAreSpacesBeforeTheCaret() {
        #expect(TextRules.endsWithSpaceAfterText("i saw the "))
        #expect(TextRules.endsWithSpaceAfterText("first line\nsecond\t"))
        #expect(!TextRules.endsWithSpaceAfterText("i saw the"))
        #expect(!TextRules.endsWithSpaceAfterText("first line\n    "))
        #expect(!TextRules.endsWithSpaceAfterText("first line\n"))
        #expect(!TextRules.endsWithSpaceAfterText(""))
    }

    @Test func randomEditsKeepTheKVBookkeepingConsistent() async throws {
        let toy = await ToyEngine.make()
        var generator = SplitMix(seed: 7)
        var text = "i saw the"
        var stages = 0
        let staged = Atomic<Int>(0)
        let pieces = [" quick", " q", "u", " lazy", " dog", ".", " a", " red", " c", "at", " ", " then"]
        for _ in 0..<120 {
            switch generator.next() % 10 {
            case 0: text = String(text.dropLast(Int(generator.next() % 4)))
            case 1: text = ["i saw the", "a cat", "the fox", "i ran"][Int(generator.next() % 4)]
            default: text += pieces[Int(generator.next() % UInt64(pieces.count))]
            }
            if text.isEmpty { text = "i" }
            let subscription = toy.engine.suggestions(for: .toy(text, after: generator.next() % 5 == 0 ? " and then" : ""))
            for _ in 0..<Int(generator.next() % 6) { _ = await toy.engine.runUnit() }
            if generator.next() % 7 == 0 { toy.engine.cancel() }
            if generator.next() % 9 == 0 {
                let prompt = ["a cat sat on the", "i saw the lazy dog and", text][Int(generator.next() % 3)]
                stages += 1
                Task {
                    _ = await toy.engine.stage(prompt: prompt)
                    staged.add(1, ordering: .relaxed)
                }
            }
            _ = subscription
        }
        while staged.load(ordering: .relaxed) < stages {
            if await toy.engine.runUnit() == nil { await Task.yield() }
        }
        while await toy.engine.runUnit() != nil {}
        await toy.engine.clearCache()
        #expect(toy.context.busySequences == 0)
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
