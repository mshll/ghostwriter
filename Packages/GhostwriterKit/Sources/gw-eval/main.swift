import Foundation
import GWCore
import Inference
import Prompting
import Synchronization

struct Row: Decodable {
    var id: String
    var app: String?
    var kind: String?
    var before: String
    var after: String?
    var truth: String?
    var reference: String?
    var lang: String?
    var source: String?
    var screen: String?
}

struct Report: Encodable {
    var model: String
    var summary: Summary
    var rows: [RowResult]
}

let fixedNow = Date(timeIntervalSince1970: 1_791_720_000)
/// The app's cap on screen text, `ScreenContextOptions.maxCharacters`.
let appScreenCharacters = 2400

func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
}

func format(_ value: Double?, _ digits: Int = 1) -> String {
    guard let value else { return "-" }
    return String(format: "%.\(digits)f", value)
}

func percent(_ value: Double?) -> String {
    guard let value else { return "-" }
    return String(format: "%.1f%%", value * 100)
}

func clip(_ text: String, _ width: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: "⏎")
    return flat.count > width ? String(flat.prefix(width - 1)) + "…" : flat
}

func loadRows(from url: URL, limit: Int?) throws -> [Row] {
    let decoder = JSONDecoder()
    let rows = try String(contentsOf: url, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .filter { !$0.allSatisfy(\.isWhitespace) }
        .map { try decoder.decode(Row.self, from: Data($0.utf8)) }
    return limit.map { Array(rows.prefix($0)) } ?? rows
}

func download(_ id: String) async throws {
    guard let spec = ModelCatalog.curated.first(where: { $0.id == id }) else {
        throw UsageError("no curated model \(id); known: \(ModelCatalog.curated.map(\.id).joined(separator: ", "))")
    }
    let lastPrinted = Atomic<Int>(-1)
    let start = ContinuousClock.now
    let url = try await ModelDownloader().download(spec) { fraction in
        let step = Int(fraction * 20)
        if lastPrinted.exchange(step, ordering: .relaxed) != step { print("download \(step * 5)%") }
    }
    print("downloaded and verified \(url.path) in \(format(milliseconds(since: start) / 1000)) s")
}

struct Harness {
    var engine: CompletionEngine
    var builder: PromptBuilder
    var options: Options

    static func load(_ options: Options, stepping: CompletionEngine.Stepping = .automatic) async throws -> Harness {
        let engine = CompletionEngine(stepping: stepping)
        let start = ContinuousClock.now
        let info = try await engine.load(modelAt: options.model, config: options.engine)
        print("model \(info.name): \(info.parameterCount / 1_000_000)M params, vocab \(info.vocabSize), load \(format(milliseconds(since: start), 0)) ms")
        guard let tokenizer = engine.tokenizer else { throw InferenceError.notLoaded }
        var builder = PromptBuilder(counter: tokenizer, budgets: options.budgets)
        builder.includeAfterText = options.afterSection
        return Harness(engine: engine, builder: builder, options: options)
    }

    func request(for row: Row, before: String, screenText: String? = nil) -> CompletionRequest {
        let after = row.after ?? ""
        let built = builder.build(PromptContext(
            appName: row.app ?? "TextEdit", fieldKind: FieldKind(rawValue: row.kind ?? "") ?? .unknown, now: fixedNow,
            screenText: screenText ?? (options.screen ? row.screen : nil), textBefore: before, textAfter: after, mode: options.draft ? .draft : .inline
        ))
        let prompt = options.promptVariant.apply(to: built.text, before: String(before.dropLast(built.partialWord.count)))
        return CompletionRequest(
            prompt: prompt, partialWord: built.partialWord, textAfter: String(after.prefix { !$0.isNewline }),
            maxWords: options.maxWords, mode: options.draft ? .draft : .inline, beams: options.beams, topK: options.topK,
            tuning: options.tuning, stopStrings: options.stopStrings ? BuiltPrompt.stopStrings : []
        )
    }

    func firstShown(_ request: CompletionRequest) async throws -> (candidates: [Candidate], milliseconds: Double, stats: GenerationStats) {
        let start = ContinuousClock.now
        for await update in engine.suggestions(for: request).updates where !update.candidates.isEmpty {
            return (update.candidates, milliseconds(since: start), GenerationStats())
        }
        return ([], milliseconds(since: start), GenerationStats())
    }

    func timed(
        _ request: CompletionRequest, onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> (candidates: [Candidate], milliseconds: Double, stats: GenerationStats) {
        let start = ContinuousClock.now
        let candidates = try await engine.complete(request, onPartial: onPartial)
        let elapsed = milliseconds(since: start)
        return (candidates, elapsed, await engine.lastStats)
    }
}

func evaluate(_ options: Options, set: URL) async throws {
    let rows = try loadRows(from: set, limit: options.limit)
    let harness = try await Harness.load(options)

    print("id     kind      cold   warm  next bad  completion -> truth")
    var results: [RowResult] = []
    var draftUpdates = 0
    var draftRewrites = 0
    var draftsStreamed = 0
    var draftsExtended = 0
    for row in rows {
        let coldRequest = harness.request(for: row, before: row.before)
        await harness.engine.clearCache()
        let partials = Mutex<[String]>([])
        let cold = options.firstShown && !options.draft
            ? try await harness.firstShown(coldRequest)
            : try await harness.timed(coldRequest) { text in partials.withLock { $0.append(text) } }
        let streamed = partials.withLock { $0 }
        if options.draft {
            draftUpdates += streamed.count
            draftRewrites += zip(streamed, streamed.dropFirst()).filter { !$1.hasPrefix($0) }.count
            if let last = streamed.last {
                draftsStreamed += 1
                if cold.candidates.first?.text.hasPrefix(last) == true { draftsExtended += 1 }
            }
        }

        var result = RowResult.score(
            id: row.id, kind: row.kind, before: row.before, after: coldRequest.textAfter, completion: cold.candidates.first?.text ?? "",
            alternatives: cold.candidates.dropFirst().map(\.text), truth: row.truth, reference: row.reference
        )
        result.coldMilliseconds = cold.milliseconds
        result.promptTokens = cold.stats.promptTokens - cold.stats.reusedTokens
        result.prefillMilliseconds = cold.stats.prefillMilliseconds
        result.steps = cold.stats.steps
        result.searchMilliseconds = cold.stats.searchMilliseconds
        result.rerankMilliseconds = cold.stats.rerankMilliseconds

        if options.warm, !options.draft, let typed = (row.truth ?? row.reference)?.first {
            let warm = try await harness.timed(harness.request(for: row, before: row.before + String(typed)))
            result.warmMilliseconds = warm.milliseconds
            result.warmCompletion = warm.candidates.first?.text
            result.reusedTokensWarm = warm.stats.reusedTokens
        }
        results.append(result)

        let next = result.exactNextWord.map { $0 ? "yes" : "no" } ?? (result.referenceNextWord.map { $0 ? "ref" : "-" } ?? "-")
        let target = row.truth ?? row.reference.map { "[ref] \($0)" } ?? ""
        print(
            row.id.padding(toLength: 6, withPad: " ", startingAt: 0),
            (row.kind ?? "").padding(toLength: 9, withPad: " ", startingAt: 0),
            format(cold.milliseconds, 0).leftPadded(5), format(result.warmMilliseconds, 0).leftPadded(5),
            next.padding(toLength: 4, withPad: " ", startingAt: 0), (result.bad ? "BAD" : "").padding(toLength: 4, withPad: " ", startingAt: 0),
            "\(clip(result.completion.isEmpty ? "(none)" : result.completion, options.draft ? 400 : 44)) -> \(clip(target, 40))"
        )
        if options.verbose {
            for alternative in result.alternatives { print(String(repeating: " ", count: 40), "alt:", clip(alternative, 60)) }
            print(String(repeating: " ", count: 40), "prompt tail:", clip(String(coldRequest.prompt.suffix(80)), 80), "| partial:", coldRequest.partialWord)
            if options.draft { print(String(repeating: " ", count: 40), "partial updates:", streamed.count) }
        }
    }

    let summary = Summary(results: results, options: options)
    print("""

        rows \(summary.rows)  variant \(summary.variant)  beams \(summary.beams)  max words \(summary.maxWords)
        exact next word     \(percent(summary.exactNextWord))   (mid-line \(percent(summary.exactNextWordMidLine)))
        accepted words      \(percent(summary.acceptedRecall)) of min(truth, max words)   precision \(percent(summary.acceptedPrecision))
        chars saved / row   \(format(summary.charsSaved))
        bad completions     \(percent(summary.badRate))   (mid-line \(percent(summary.badRateMidLine)))
        label echo          \(percent(summary.labelEchoRate))   verbatim copy \(percent(summary.verbatimCopyRate))
        empty               \(percent(summary.emptyRate))   (mid-line \(percent(summary.emptyRateMidLine)))
        reference next word \(percent(summary.referenceNextWord))
        words / completion  \(format(summary.meanCompletionWords, 2))
        latency cold p50/p95 \(format(summary.coldP50, 0)) / \(format(summary.coldP95, 0)) ms
        latency warm p50/p95 \(format(summary.warmP50, 0)) / \(format(summary.warmP95, 0)) ms
        prefill \(format(summary.prefillTokensPerSecond, 0)) tok/s   step \(format(summary.stepMilliseconds)) ms   steps/row \(format(summary.meanSteps))
        """)

    if options.draft {
        print("draft streaming     \(draftUpdates) updates, \(draftRewrites) not extending the one before, final extends the last update in \(draftsExtended) of \(draftsStreamed)")
    }

    if let json = options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Report(model: options.model.lastPathComponent, summary: summary, rows: results)).write(to: json)
        print("wrote \(json.path)")
    }
}

struct KeystrokeSample {
    var milliseconds: Double
    var stats: GenerationStats
}

func bench(_ options: Options, set: URL) async throws {
    let rows = try loadRows(from: set, limit: nil).filter { $0.truth != nil }
    let harness = try await Harness.load(options)
    let screen = rows.map(\.before).joined(separator: "\n\n")
    let sample = Array(rows.prefix(options.limit ?? 12))

    var cold: [KeystrokeSample] = []
    var steady: [KeystrokeSample] = []
    var burst: [Double] = []
    var cancelLatency: [[Double]] = [[], []]
    var cancelled = 0
    var swaps: [KeystrokeSample] = []
    let swapScreen = String(rows.reversed().map(\.before).joined(separator: "\n\n").prefix(appScreenCharacters))
    for row in sample {
        await harness.engine.clearCache()
        let first = try await harness.timed(harness.request(for: row, before: row.before, screenText: screen))
        cold.append(KeystrokeSample(milliseconds: first.milliseconds, stats: first.stats))

        let typed = Array(row.truth ?? "").prefix(10)
        for count in 1...max(typed.count, 1) {
            let request = harness.request(for: row, before: row.before + String(typed.prefix(count)), screenText: screen)
            let result = try await harness.timed(request)
            steady.append(KeystrokeSample(milliseconds: result.milliseconds, stats: result.stats))
        }

        var tasks: [(Task<[Candidate], any Error>, ContinuousClock.Instant)] = []
        for extra in 1...5 {
            harness.engine.cancel()
            let request = harness.request(for: row, before: row.before + String(typed) + String(repeating: "x", count: extra), screenText: screen)
            tasks.append((Task { try await harness.engine.complete(request) }, .now))
            try await Task.sleep(for: .milliseconds(3))
        }
        for (task, issued) in tasks {
            do {
                _ = try await task.value
                if task == tasks.last?.0 { burst.append(milliseconds(since: issued)) }
            } catch is CancellationError {
                cancelled += 1
            }
        }

        for (phase, delay) in [(0, 300), (1, 40)] {
            let before = row.before + String(typed)
            if phase == 0 { await harness.engine.clearCache() } else { _ = try await harness.timed(harness.request(for: row, before: before, screenText: screen)) }
            let request = harness.request(for: row, before: before + (phase == 0 ? "" : "e"), screenText: screen)
            let task = Task { try await harness.engine.complete(request) }
            try await Task.sleep(for: .milliseconds(delay))
            let cancelledAt = ContinuousClock.now
            harness.engine.cancel()
            do {
                _ = try await task.value
            } catch is CancellationError {
                cancelLatency[phase].append(milliseconds(since: cancelledAt))
            }
        }

        let typedBefore = row.before + String(typed)
        _ = try await harness.timed(harness.request(for: row, before: typedBefore, screenText: screen))
        let swapped = try await harness.timed(harness.request(for: row, before: typedBefore, screenText: swapScreen))
        swaps.append(KeystrokeSample(milliseconds: swapped.milliseconds, stats: swapped.stats))
    }

    func describe(_ name: String, _ samples: [KeystrokeSample]) {
        let ms = samples.map(\.milliseconds)
        func mean(_ value: (GenerationStats) -> Double) -> String { format(samples.map { value($0.stats) }.reduce(0, +) / Double(max(samples.count, 1))) }
        print("""
            \(name): n \(samples.count)  p50 \(format(Metrics.percentile(ms, 0.5), 0)) ms  p95 \(format(Metrics.percentile(ms, 0.95), 0)) ms
              mean breakdown: tokenize \(mean { $0.tokenizeMilliseconds }) ms, prompt \(mean { Double($0.promptTokens) }) tok of which decoded \(mean { Double($0.promptTokens - $0.reusedTokens) }) in \(mean { $0.prefillMilliseconds }) ms, search \(mean { $0.searchMilliseconds }) ms over \(mean { Double($0.steps) }) steps (\(format(samples.map { $0.stats.searchMilliseconds }.reduce(0, +) / Double(max(1, samples.map { $0.stats.steps }.reduce(0, +))))) ms/step), rerank \(mean { $0.rerankMilliseconds }) ms
            """)
    }
    print("beams \(options.beams), max words \(options.maxWords), confidence \(options.tuning.confidenceRatio), early stop \(options.tuning.earlyStopMargin.map { format($0) } ?? "off")")
    describe("cold (new prompt, empty cache)", cold)
    let coldRates = cold.map { Double($0.stats.promptTokens - $0.stats.reusedTokens) / $0.stats.prefillMilliseconds * 1000 }
    print("  cold prefill median \(format(Metrics.percentile(coldRates, 0.5), 0)) tok/s")
    describe("steady typing (+1 char, awaited)", steady)
    describe("  of which end of line", steady.filter { $0.stats.rerankMilliseconds == 0 })
    describe("  of which mid-line", steady.filter { $0.stats.rerankMilliseconds > 0 })
    for (name, samples) in zip(["prefill", "search"], cancelLatency) {
        print("cancel during \(name): n \(samples.count)  p50 \(format(Metrics.percentile(samples, 0.5), 0)) ms  max \(format(samples.max() ?? 0, 0)) ms until CancellationError")
    }
    describe("screen swap (\(appScreenCharacters) new characters of screen text, same typed text)", swaps)
    print("burst (5 requests, each after cancel()): last result \(format(Metrics.percentile(burst, 0.5), 0)) ms p50 after issue, \(cancelled) of \(sample.count * 5) cancelled")
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    if let id = options.download {
        try await download(id)
    } else if let set = options.set {
        switch options.task {
        case .evaluate: try await evaluate(options, set: set)
        case .bench: try await bench(options, set: set)
        case .swap: try await simulateSwap(options, set: set, mode: options.swapMode)
        case .pause: try await simulatePause(options, set: set)
        case .score: try await score(options, set: set)
        case .typos: try await evaluateTypos(options, set: set)
        case .proofread: try await evaluateProofread(options, set: set)
        case .typing:
            if let mode = options.engineMode {
                try await simulateClocked(options, set: set, mode: mode)
            } else {
                try await simulateTyping(options, set: set)
            }
        }
    }
} catch let error as UsageError {
    if let message = error.message { print("error: \(message)") }
    print(Options.usage)
    exit(2)
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
