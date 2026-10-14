import Foundation
import GWCore
import Testing
@testable import Inference

@Suite struct LogitMathTests {
    @Test func logSumExpMatchesDirectSum() {
        let logits: [Float] = [1, 2, 3, -1]
        let expected = log(logits.map { exp($0) }.reduce(0, +))
        var scratch = [Float](repeating: 0, count: logits.count)
        let value = logits.withUnsafeBufferPointer { input in
            scratch.withUnsafeMutableBufferPointer { LogitMath.logSumExp(input, scratch: $0) }
        }
        #expect(abs(value - expected) < 1e-5)
    }

    @Test func logSumExpStaysFiniteForLargeLogits() {
        let logits: [Float] = [1000, 1000]
        var scratch = [Float](repeating: 0, count: 2)
        let value = logits.withUnsafeBufferPointer { input in
            scratch.withUnsafeMutableBufferPointer { LogitMath.logSumExp(input, scratch: $0) }
        }
        #expect(abs(value - (1000 + log(2))) < 1e-3)
    }

    @Test func topKReturnsHighestFirstWithStableTies() {
        let logits: [Float] = [0.5, 3, -2, 3, 1]
        let top = logits.withUnsafeBufferPointer { LogitMath.topK($0, k: 3) }
        #expect(top.map(\.token) == [1, 3, 4])
    }

    @Test func topKWithKLargerThanInput() {
        let logits: [Float] = [2, 1]
        let top = logits.withUnsafeBufferPointer { LogitMath.topK($0, k: 5) }
        #expect(top.map(\.token) == [0, 1])
    }

    @Test func normalizedScoreInterpolatesBetweenSumAndMean() {
        #expect(LogitMath.normalizedScore(logprob: -6, tokens: 3, lengthPenalty: 0) == -6)
        #expect(LogitMath.normalizedScore(logprob: -6, tokens: 3, lengthPenalty: 1) == -2)
        #expect(LogitMath.normalizedScore(logprob: -6, tokens: 0, lengthPenalty: 1) == -6)
    }
}

@Suite struct TextRuleTests {
    @Test(arguments: [
        ("Thanks for the update.", SentenceEnd.definite),
        ("Can we merge it?", .definite),
        ("He said \"ok.\"", .definite),
        ("それでいいです。", .definite),
        ("revenue grew by 15.", .ambiguous),
        ("for example, e.g.", .ambiguous),
        ("ask Dr.", .ambiguous),
        ("wait...", .definite),
        ("no ending here", .none),
    ])
    func sentenceEnds(text: String, expected: SentenceEnd) {
        #expect(TextRules.sentenceEnd(of: text) == expected)
    }

    @Test func wordUnitsCountWordsAndHalveCJK() {
        #expect(TextRules.wordUnits(" my previous email") == 3)
        #expect(TextRules.wordUnits("don't over-think it") == 3)
        #expect(TextRules.wordUnits(", and") == 1)
        #expect(TextRules.wordUnits("お願いします") == 3)
        #expect(TextRules.wordUnits("") == 0)
    }

    @Test func trimsOnlyTheDanglingWord() {
        #expect(TextRules.trimmingPartialWord(" discuss the des") == " discuss the ")
        #expect(TextRules.trimmingPartialWord("previ") == "")
        #expect(TextRules.trimmingPartialWord(" merge it.") == " merge it.")
    }

    @Test func continuationPiecesExtendWords() {
        #expect(TextRules.continuesWord("ign"))
        #expect(TextRules.continuesWord("'t"))
        #expect(!TextRules.continuesWord(" the"))
        #expect(!TextRules.continuesWord(","))
        #expect(!TextRules.continuesWord(""))
    }

    @Test func partialWordConstraintAcceptsPrefixesBothWays() {
        #expect(pieceSatisfies(Array(" previous".utf8), Array(" pr".utf8)))
        #expect(pieceSatisfies(Array(" p".utf8), Array(" pr".utf8)))
        #expect(pieceSatisfies(Array(" pr".utf8), Array(" pr".utf8)))
        #expect(!pieceSatisfies(Array(" po".utf8), Array(" pr".utf8)))
        #expect(!pieceSatisfies([UInt8](), Array(" pr".utf8)))
    }

    @Test func commonPrefixOfTokenLists() {
        #expect(commonPrefixLength([1, 2, 3, 4], [1, 2, 9]) == 2)
        #expect(commonPrefixLength([1, 2], [1, 2, 3]) == 2)
        #expect(commonPrefixLength([Int32](), [1]) == 0)
    }

    @Test func decodingDropsIncompleteTrailingCharacter() {
        let bytes = Array("café".utf8)
        #expect(TextRules.decodeComplete(bytes) == "café")
        #expect(TextRules.decodeComplete(bytes.dropLast()) == "caf")
        #expect(TextRules.decodeComplete(Array("日本".utf8).dropLast(2)) == "日")
    }

    @Test func trailingSpacesMoveIntoTheRequiredPrefix() {
        #expect(TextRules.splitTrailingSpaces("follow up on  ") == ("follow up on", "  "))
        #expect(TextRules.splitTrailingSpaces("on") == ("on", ""))
    }

    @Test func lastWordBeforeTrailingSpaces() {
        #expect(TextRules.lastWord(of: "follow up on ") == "on")
        #expect(TextRules.lastWord(of: "it's") == "it's")
        #expect(TextRules.lastWord(of: "done,") == nil)
    }

    @Test func blankLinesMayContainSpaces() {
        #expect(TextRules.containsBlankLine(Array("you! \n \nBest".utf8)))
        #expect(TextRules.containsBlankLine(Array("end.\n\n".utf8)))
        #expect(!TextRules.containsBlankLine(Array("- milk\n- eggs\n".utf8)))
    }

    @Test func detectsPhraseLoops() {
        #expect(TextRules.repeatsLastBigram(", no blockers, no blockers"))
        #expect(!TextRules.repeatsLastBigram(" one more time"))
    }

    @Test func midLineInsertionKeepsWordsApart() {
        #expect(TextRules.insertion("on", before: "Tuesday at noon") == "on ")
        #expect(TextRules.insertion(" on", before: " Tuesday") == " on")
        #expect(TextRules.insertion("end", before: ", then") == "end")
        #expect(TextRules.insertion("に", before: "行きます") == "に")
    }

    @Test func midLineInsertionsThatBreakTheLineClash() {
        #expect(TextRules.clashes(insertion: "3:00?", before: " en la puerta"))
        #expect(TextRules.clashes(insertion: "an analogy.", before: " as an analogy, in under 200 words."))
        #expect(TextRules.clashes(insertion: " the", before: " the report"))
        #expect(!TextRules.clashes(insertion: " on", before: " Tuesday at the main office."))
        #expect(TextRules.clashes(insertion: " soon,", before: ", and then"))
    }

    @Test func echoGuardCatchesCopiedSpans() throws {
        let source = "Hi Dana, thanks for sending the revised budget for the spring launch over so quickly."
        let grams = TextRules.wordGrams(TextRules.words(source), length: TextRules.echoWords)
        #expect(TextRules.echoes(" thanks for sending the revised budget for the spring", source: source, sourceGrams: grams))
        #expect(TextRules.echoes(" we can meet, we can talk, we can meet, we can talk, we can meet", source: "", sourceGrams: []))
        #expect(TextRules.echoes(" the revised budget for the spring launch over so", source: source, sourceGrams: []))
        #expect(!TextRules.echoes(" I will review it tomorrow morning and reply", source: source, sourceGrams: grams))

        let draft = " Sounds good. Hi Dana, thanks for sending the revised budget for the spring"
        let start = try #require(TextRules.echoStart(draft, source: source, sourceGrams: grams))
        #expect(draft[start...] == "for sending the revised budget for the spring")
        #expect(TextRules.trimmingToBoundary(String(draft[..<start])) == " Sounds good.")
        #expect(TextRules.trimmingToBoundary("First line\nsecond li") == "First line")
        #expect(TextRules.trimmingToBoundary(" no boundary here ye") == " no boundary here ")
        #expect(TextRules.truncatingAtRepeatedLine(".\nstandup: no blockers.\nstandup: no blockers.") == ".\nstandup: no blockers.\n")
        #expect(TextRules.truncatingAtRepeatedLine("ok\nok\nok") == "ok\nok\nok")
    }
}

@Suite struct CatalogTests {
    @Test(arguments: [
        ("Apple M1", 0), ("Apple M1 Pro", 1), ("Apple M2", 1), ("Apple M2 Pro", 2), ("Apple M3 Pro", 1),
        ("Apple M4 Max", 3), ("Apple M5 Pro", 2), ("Apple M2 Ultra", 3), ("Intel(R) Core(TM) i9", 0),
    ])
    func chipTiers(chip: String, tier: Int) {
        #expect(HardwareProfile.tier(forChip: chip) == tier)
    }

    @Test func recommendationFollowsMemoryAndTier() {
        func pick(_ chip: String, _ memory: Int) -> String? {
            ModelCatalog.recommended(for: HardwareProfile(chip: chip, tier: HardwareProfile.tier(forChip: chip), memoryGB: memory))?.id
        }
        #expect(pick("Apple M1 Pro", 16) == "gemma-4-e2b")
        #expect(pick("Apple M2 Pro", 32) == "gemma-4-e4b")
        #expect(pick("Apple M4", 24) == "gemma-4-e4b")
        #expect(pick("Apple M3", 24) == "gemma-4-e2b")
        #expect(pick("Apple M1", 8) == "gemma-3-1b")
    }

    @Test func curatedModelsCarryChecksumsAndRevisions() throws {
        #expect(ModelCatalog.curated.count == 4)
        for spec in ModelCatalog.curated {
            #expect(spec.sha256?.count == 64)
            #expect(spec.sizeBytes > 0)
            let revision = try #require(spec.revision)
            #expect(revision.count == 40 && revision.allSatisfy(\.isHexDigit))
            #expect(spec.downloadURL?.absoluteString.hasPrefix("https://huggingface.co/\(spec.repo)/resolve/\(revision)/") == true)
        }
    }

    @Test func streamedChecksumMatchesKnownDigest() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "gw-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let digest = try await ModelDownloader.sha256(of: file)
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite(.serialized) struct EngineIntegrationTests {
    static let modelURL = AppPaths.models.appending(path: "gemma-4-E2B-Q5_K_M-gates8.gguf")
    static let modelPresent = FileManager.default.fileExists(atPath: modelURL.path)

    @Test(.enabled(if: modelPresent)) func completesHealsReusesAndCancels() async throws {
        let engine = CompletionEngine()
        let info = try await engine.load(modelAt: Self.modelURL, config: EngineConfig())
        #expect(info.vocabSize > 1000)
        #expect(engine.tokenizer?.countTokens("Hello world") ?? 0 > 0)

        let prompt = "Thank you so much for the birthday gift, I really "
        let plain = try await engine.complete(CompletionRequest(prompt: prompt, maxWords: 4))
        let best = try #require(plain.first)
        #expect(TextRules.hasWordCharacter(best.text))
        #expect(!best.text.contains("\n"))
        #expect(TextRules.wordUnits(best.text) <= 4)

        let healed = try await engine.complete(CompletionRequest(prompt: prompt, partialWord: "appre", maxWords: 4))
        let healedBest = try #require(healed.first)
        #expect(healedBest.text.first?.isLetter == true)
        #expect(("appre" + healedBest.text).hasPrefix("apprec"))
        let stats = await engine.lastStats
        #expect(stats.reusedTokens == stats.promptTokens)

        let midLine = try await engine.complete(CompletionRequest(
            prompt: "The meeting is scheduled for next ", partialWord: "week", textAfter: " Tuesday at the main office.", maxWords: 4
        ))
        #expect(midLine.allSatisfy { TextRules.hasWordCharacter($0.text) && !TextRules.clashes(insertion: $0.text, before: " Tuesday") })

        let biased = try await engine.complete(CompletionRequest(
            prompt: "For lunch today I am eating ", maxWords: 2,
            bias: TokenBias(followers: ["eating": ["broccoli": 1000]], strength: 4)
        ))
        #expect(biased.first?.text.lowercased().contains("broccoli") == true)

        let stopped = try await engine.complete(CompletionRequest(prompt: "Counting up: 1, 2, 3, 4, 5,", maxWords: 4, stopStrings: [" 7"]))
        #expect(!stopped.isEmpty)
        #expect(stopped.allSatisfy { !$0.text.contains("7") })
        let listed = try await engine.complete(CompletionRequest(
            prompt: "Shopping list:\n- apples\n- pears\n- milk", maxWords: 8, mode: .draft, stopStrings: ["\n- "]
        ))
        #expect(listed.allSatisfy { !$0.text.contains("\n- ") })

        var streamed: SuggestionUpdate?
        for await update in engine.suggestions(for: CompletionRequest(prompt: prompt, maxWords: 4)).updates { streamed = update }
        let streamedBest = try #require(streamed?.candidates.first)
        #expect(streamed?.isFinal == true)
        #expect(TextRules.wordUnits(streamedBest.text) <= 4)
        var followed: SuggestionUpdate?
        let typed = String(streamedBest.text.prefix { $0.isLetter }.prefix(3))
        #expect(!typed.isEmpty)
        for await update in engine.suggestions(for: CompletionRequest(prompt: prompt, partialWord: typed, maxWords: 4)).updates {
            followed = update
        }
        #expect(followed?.reused == true)
        #expect(followed?.candidates.isEmpty == false)

        let task = Task { try await engine.complete(CompletionRequest(prompt: "A completely different prompt about", maxWords: 4)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let draft = Task {
            try await engine.complete(CompletionRequest(prompt: "Dear team,\n\nHere is a long update on", maxWords: 80, mode: .draft))
        }
        try await Task.sleep(for: .milliseconds(150))
        let quitStarted = ContinuousClock.now
        engine.cancel()
        await engine.unload()
        #expect(quitStarted.duration(to: .now) < .milliseconds(300))
        #expect(await engine.isLoaded == false)
        do {
            _ = try await draft.value
        } catch is CancellationError {
            // Expected unless the draft finished before the cancel.
        }
        await engine.unload()
    }
}
