import Dispatch
import Foundation
import GWCore
import llama
import os
import Synchronization

/// Runs on its own serial queue so multi-millisecond decodes never occupy the cooperative pool.
public actor CompletionEngine {
    public enum Stepping: Sendable {
        case automatic
        case manual
    }

    static let maxBeams = 8
    /// Sequence 0, live beams, parked beams, the mid-line rerank's sequences and the staging sequence.
    static let sequenceCount = 1 + maxBeams + BeamSearch.parkLimit + 4 + 1

    private struct StageRequest: Sendable {
        var prompt: String
        var continuation: CheckedContinuation<Bool, Never>?
    }

    private nonisolated let queue = DispatchSerialQueue(label: "com.mshl.ghostwriter.inference", qos: .userInitiated)
    private nonisolated let abort = AbortSignal()
    private nonisolated let tokenizerSlot = Mutex<LlamaVocabulary?>(nil)
    private nonisolated let mailbox = Mutex<Scheduler.Submission?>(nil)
    private nonisolated let draining = Atomic<Bool>(false)
    private nonisolated let submissions = Atomic<Int>(0)
    private nonisolated let stageBox = Mutex<StageRequest?>(nil)
    private var staging: (tokens: [Int32], continuation: CheckedContinuation<Bool, Never>?)?
    private var stagedInUnit = false
    private nonisolated let stepping: Stepping
    private var session: Session?
    private var scheduler: Scheduler?
    private let log = Logger.gw("inference")

    public private(set) var lastStats = GenerationStats()

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(stepping: Stepping = .automatic) {
        self.stepping = stepping
    }

    public func load(modelAt url: URL, config: EngineConfig) throws -> LoadedModelInfo {
        unload()
        let model = try LlamaModel(url: url, gpuLayers: config.gpuLayers)
        let vocabulary = LlamaVocabulary(model: try LlamaModel(url: url, gpuLayers: 0, vocabularyOnly: true))
        let context = try LlamaContext(model: model, config: config, sequences: Self.sequenceCount, abort: abort)
        attach(Session(
            vocabulary: vocabulary, context: context, maxBeams: Self.maxBeams, sequences: Self.sequenceCount,
            rowSlots: BeamSearch.parkLimit, stagingChunk: config.stagingChunk
        ))
        tokenizerSlot.withLock { $0 = vocabulary }
        return LoadedModelInfo(
            name: model.metadata("general.name") ?? url.deletingPathExtension().lastPathComponent,
            parameterCount: Int64(llama_model_n_params(model.pointer)),
            sizeBytes: Int64(llama_model_size(model.pointer)),
            vocabSize: vocabulary.count
        )
    }

    func attach(_ session: Session) {
        self.session = session
        let scheduler = Scheduler(session: session, abort: abort)
        scheduler.collectsPublications = stepping == .manual
        self.scheduler = scheduler
    }

    /// Frees the context and the GPU model. Call before the process exits: ggml aborts at exit while Metal
    /// buffers are alive. Tokenizers handed out earlier keep working; they hold a weights-free copy of the vocabulary.
    public func unload() {
        scheduler?.reset()
        scheduler = nil
        session = nil
        let queued = mailbox.withLock { slot in
            defer { slot = nil }
            return slot
        }
        queued?.continuation?.finish()
        let stage = stageBox.withLock { slot in
            defer { slot = nil }
            return slot
        }
        stage?.continuation?.resume(returning: false)
        staging?.continuation?.resume(returning: false)
        staging = nil
        tokenizerSlot.withLock { $0 = nil }
    }

    public var isLoaded: Bool { session != nil }

    public nonisolated var tokenizer: (any TokenCounting)? { tokenizerSlot.withLock { $0 } }

    // MARK: Continuous suggestions

    public nonisolated func suggestions(for request: CompletionRequest) -> SuggestionSubscription {
        let (updates, continuation) = AsyncStream.makeStream(of: SuggestionUpdate.self, bufferingPolicy: .bufferingNewest(4))
        let id = submissions.add(1, ordering: .relaxed).newValue
        let submission = Scheduler.Submission(id: id, request: request, ticket: abort.ticket, continuation: continuation, submitted: .now)
        let replaced = mailbox.withLock { slot in
            defer { slot = submission }
            return slot
        }
        replaced?.continuation?.finish()
        if stepping == .automatic { wake() }
        return SuggestionSubscription(id: id, updates: updates)
    }

    public func runUnit() -> EngineUnit? {
        let started = ContinuousClock.now
        stagedInUnit = false
        let worked = runNextUnit() || runStageUnit()
        let publications = scheduler?.takePublications() ?? []
        guard worked || !publications.isEmpty else { return nil }
        return EngineUnit(milliseconds: started.duration(to: .now).milliseconds, publications: publications, staged: stagedInUnit)
    }

    private nonisolated func wake() {
        guard draining.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        Task { await self.drain() }
    }

    private func drain() async {
        while true {
            if runNextUnit() || runStageUnit() {
                await Task.yield()
                continue
            }
            draining.store(false, ordering: .releasing)
            guard mailbox.withLock({ $0 != nil }) || stageBox.withLock({ $0 != nil }),
                  draining.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
            else { return }
        }
    }

    private func runStageUnit() -> Bool {
        if let next = stageBox.withLock({ slot in
            defer { slot = nil }
            return slot
        }) {
            staging?.continuation?.resume(returning: false)
            guard let session else {
                staging = nil
                next.continuation?.resume(returning: false)
                return false
            }
            var stats = GenerationStats()
            staging = (session.prepare(prompt: next.prompt, partialWord: "", stats: &stats).tokens, next.continuation)
        }
        guard let session, let current = staging else { return false }
        abort.begin(abort.ticket)
        let typing = scheduler?.lastSubmitted.map { $0.duration(to: .now) < .seconds(1) } ?? false
        do {
            switch try session.stageChunk(current.tokens, limit: typing ? session.stagingChunk : Session.prefillChunk, abort: abort) {
            case .working:
                return true
            case .done:
                break
            case .noRoom:
                scheduler?.reset()
                guard try session.prefillChunk(current.tokens, abort: abort) else { return true }
            }
            staging = nil
            stagedInUnit = true
            current.continuation?.resume(returning: true)
        } catch is CancellationError {
            // A cancel aimed at a request landed mid-chunk; the staging goes on at the next idle unit.
        } catch {
            log.error("Staging a prompt failed: \(error.localizedDescription, privacy: .public)")
            staging = nil
            current.continuation?.resume(returning: false)
        }
        return true
    }

    private func runNextUnit() -> Bool {
        let next = mailbox.withLock { slot in
            defer { slot = nil }
            return slot
        }
        guard let scheduler else {
            next?.continuation?.finish()
            return false
        }
        if let next { scheduler.adopt(next) }
        return scheduler.runUnit()
    }

    // MARK: One-shot requests

    public nonisolated func prewarm(prompt: String) async {
        _ = await stage(prompt: prompt)
    }

    public nonisolated func stage(prompt: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let replaced = stageBox.withLock { slot in
                defer { slot = StageRequest(prompt: prompt, continuation: continuation) }
                return slot
            }
            replaced?.continuation?.resume(returning: false)
            if stepping == .automatic { wake() }
        }
    }

    public func clearCache() {
        scheduler?.reset()
        session?.clearCache()
    }

    public nonisolated func cancel() {
        abort.cancel()
    }

    public nonisolated func score(prompt: String, continuation: String) async throws -> ContinuationScore {
        try await score(prompt: prompt, continuation: continuation, ticket: abort.ticket)
    }

    private func score(prompt: String, continuation: String, ticket: Int) throws -> ContinuationScore {
        guard let session else { throw InferenceError.notLoaded }
        scheduler?.reset()
        abort.begin(ticket)
        return try session.score(prompt: prompt, continuation: continuation, abort: abort)
    }

    public nonisolated func complete(
        _ request: CompletionRequest,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> [Candidate] {
        try await complete(request, ticket: abort.ticket, onPartial: onPartial)
    }

    private func complete(_ request: CompletionRequest, ticket: Int, onPartial: (@Sendable (String) -> Void)?) throws -> [Candidate] {
        guard let session else { throw InferenceError.notLoaded }
        scheduler?.reset()
        abort.begin(ticket)
        var stats = GenerationStats()
        defer { lastStats = stats }
        return try Self.run(request, session: session, abort: abort, stats: &stats, onPartial: onPartial)
    }

    private static func run(
        _ request: CompletionRequest, session: Session, abort: AbortSignal, stats: inout GenerationStats,
        onPartial: (@Sendable (String) -> Void)?
    ) throws -> [Candidate] {
        let started = ContinuousClock.now
        defer { stats.totalMilliseconds = started.duration(to: .now).milliseconds }
        if abort.isCancelled || Task.isCancelled { throw CancellationError() }
        let prompt = session.prepare(prompt: request.prompt, partialWord: request.partialWord, stats: &stats)
        guard !prompt.tokens.isEmpty else { return [] }
        try session.prefill(prompt.tokens, abort: abort, stats: &stats)

        let searchStarted = ContinuousClock.now
        let search = BeamSearch(session: session, request: request, prompt: prompt, abort: abort, parks: false)
        defer { search.release() }
        try search.start()
        var streamed = ""
        while !search.isDone {
            try search.step()
            if let onPartial, request.mode == .draft, let stable = search.stableText, stable.count > streamed.count,
               stable.hasPrefix(streamed) {
                streamed = stable
                onPartial(stable)
            }
        }
        var candidates = search.ranked()
        if !streamed.isEmpty {
            // Text already on screen stays: the best candidate that extends it wins. When the search stopped
            // early on a finished beam that does not, the live beams that do still count, cut to whole words.
            var extending = candidates.filter { $0.text.hasPrefix(streamed) }
            if extending.isEmpty { extending = search.provisional().filter { $0.text.hasPrefix(streamed) } }
            if !extending.isEmpty { candidates = extending + candidates.filter { !$0.text.hasPrefix(streamed) } }
        }
        stats.steps = search.steps
        stats.searchMilliseconds = searchStarted.duration(to: .now).milliseconds

        if request.mode == .inline, !request.textAfter.isEmpty, !candidates.isEmpty {
            let rerankStarted = ContinuousClock.now
            var totals: [[Int32]: Double] = [:]
            candidates = try session.rerankMidLine(
                candidates, required: prompt.required, textAfter: request.textAfter, tuning: request.tuning, totals: &totals
            )
            stats.rerankMilliseconds = rerankStarted.duration(to: .now).milliseconds
        }
        return candidates
    }
}
