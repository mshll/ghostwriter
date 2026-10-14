import Foundation

struct PreparedPrompt {
    var tokens: [Int32]
    var required: [UInt8]
    var body: [UInt8]
    var tail: String
    var context: String
}

enum StageProgress {
    case working
    case done
    case noRoom
}

final class Session {
    static let baseSequence: Int32 = 0
    private static let generationReserve = 512
    /// Tokens per prefill decode call; cancellation is checked between calls because Metal ignores llama's abort callback.
    static let prefillChunk = 128
    static let echoWindow = 2000

    let vocabulary: LlamaVocabulary
    let context: any DecodeContext
    let maxBeams: Int
    private var cachedTokens: [Int32] = []
    private var hasPromptLogits = false
    private(set) var rootVersion = 0
    let promptLogits: UnsafeMutableBufferPointer<Float>
    let scratch: UnsafeMutableBufferPointer<Float>
    let workRow: UnsafeMutableBufferPointer<Float>
    private var freeSequences: [Int32]
    private let rows: UnsafeMutablePointer<Float>
    private var freeRows: [Int]
    private var firstTokens: [String: Int32?] = [:]
    let stagingSequence: Int32
    private var stagedTokens: [Int32] = []
    private var hasStagedLogits = false
    private let stagedLogits: UnsafeMutableBufferPointer<Float>
    let stagingChunk: Int

    init(
        vocabulary: LlamaVocabulary, context: any DecodeContext, maxBeams: Int, sequences: Int, rowSlots: Int,
        stagingChunk: Int = EngineConfig().stagingChunk
    ) {
        self.vocabulary = vocabulary
        self.context = context
        self.maxBeams = maxBeams
        self.stagingChunk = max(1, stagingChunk)
        promptLogits = .allocate(capacity: vocabulary.count)
        scratch = .allocate(capacity: vocabulary.count)
        workRow = .allocate(capacity: vocabulary.count)
        stagedLogits = .allocate(capacity: vocabulary.count)
        stagingSequence = Int32(sequences - 1)
        freeSequences = (1..<Int32(sequences - 1)).reversed()
        rows = .allocate(capacity: max(vocabulary.count * rowSlots, 1))
        freeRows = Array((0..<rowSlots).reversed())
    }

    deinit {
        promptLogits.deallocate()
        scratch.deallocate()
        workRow.deallocate()
        stagedLogits.deallocate()
        rows.deallocate()
    }

    var promptLength: Int { cachedTokens.count }

    func clearCache() {
        context.clearAll()
        cachedTokens = []
        hasPromptLogits = false
        stagedTokens = []
        hasStagedLogits = false
        rootVersion += 1
    }

    func allocateSequence() -> Int32? {
        freeSequences.popLast()
    }

    func releaseSequence(_ sequence: Int32) {
        guard sequence != Self.baseSequence else { return }
        precondition(!freeSequences.contains(sequence), "sequence \(sequence) released twice")
        context.clearSequence(sequence)
        freeSequences.append(sequence)
    }

    var freeSequenceCount: Int { freeSequences.count }

    func allocateRow() -> Int? {
        freeRows.popLast()
    }

    func releaseRow(_ slot: Int) {
        precondition(!freeRows.contains(slot), "row \(slot) released twice")
        freeRows.append(slot)
    }

    func row(_ slot: Int) -> UnsafeMutablePointer<Float> {
        rows + slot * vocabulary.count
    }

    func prepare(prompt: String, partialWord: String, stats: inout GenerationStats) -> PreparedPrompt {
        let started = ContinuousClock.now
        defer { stats.tokenizeMilliseconds = started.duration(to: .now).milliseconds }
        let (body, spaces) = TextRules.splitTrailingSpaces(prompt)
        var tokens = vocabulary.tokenize(body, addSpecial: true)
        let limit = context.contextSize - Self.generationReserve
        if tokens.count > limit {
            let bos = tokens.first.map { $0 == vocabulary.bos ? [$0] : [] } ?? []
            tokens = bos + tokens.suffix(limit - bos.count)
        }
        return PreparedPrompt(
            tokens: tokens, required: Array((spaces + partialWord).utf8), body: Array(body.utf8), tail: String(body.suffix(64)),
            context: String(body.suffix(Self.echoWindow))
        )
    }

    func isPrefilled(_ tokens: [Int32]) -> Bool {
        hasPromptLogits && cachedTokens == tokens
    }

    func prefill(_ tokens: [Int32], abort: AbortSignal, stats: inout GenerationStats) throws {
        let started = ContinuousClock.now
        defer { stats.prefillMilliseconds = started.duration(to: .now).milliseconds }
        stats.promptTokens = tokens.count
        stats.reusedTokens = min(commonPrefixLength(cachedTokens, tokens), tokens.count - 1)
        if isPrefilled(tokens) { stats.reusedTokens = tokens.count }
        while try !prefillChunk(tokens, abort: abort) {}
    }

    func prefillChunk(_ tokens: [Int32], abort: AbortSignal) throws -> Bool {
        adoptStaged(ifCloserTo: tokens)
        if isPrefilled(tokens) { return true }
        if !stagedTokens.isEmpty,
           tokens.count + stagedTokens.count - commonPrefixLength(stagedTokens, cachedTokens) + Self.generationReserve > context.contextSize {
            context.clearSequence(stagingSequence)
            stagedTokens = []
            hasStagedLogits = false
        }
        if abort.isCancelled || Task.isCancelled { throw CancellationError() }
        var reuse = min(commonPrefixLength(cachedTokens, tokens), tokens.count - 1)
        if reuse < cachedTokens.count {
            if !context.removeTokens(sequence: Self.baseSequence, from: reuse) {
                context.clearAll()
                reuse = 0
            }
            cachedTokens.removeSubrange(reuse...)
        }
        hasPromptLogits = false
        rootVersion += 1
        let end = min(reuse + Self.prefillChunk, tokens.count)
        let entries = (reuse..<end).map {
            DecodeEntry(token: tokens[$0], position: $0, sequence: Self.baseSequence, wantsLogits: $0 == tokens.count - 1)
        }
        do {
            try context.decode(entries)
        } catch {
            cachedTokens = Array(tokens.prefix(context.maxPosition(sequence: Self.baseSequence) + 1))
            throw error
        }
        cachedTokens.append(contentsOf: tokens[reuse..<end])
        guard end == tokens.count else { return false }
        guard let logits = context.logits(at: -1) else {
            throw InferenceError.decodeFailed(-1)
        }
        _ = promptLogits.update(fromContentsOf: UnsafeBufferPointer(start: logits, count: vocabulary.count))
        hasPromptLogits = true
        return true
    }

    func stageChunk(_ tokens: [Int32], limit: Int, abort: AbortSignal) throws -> StageProgress {
        // Sequence 0 already holds it (a request needs at most its last token again), or the staging does.
        if commonPrefixLength(cachedTokens, tokens) == tokens.count || (hasStagedLogits && stagedTokens == tokens) { return .done }
        if abort.isCancelled || Task.isCancelled { throw CancellationError() }
        let shared = min(commonPrefixLength(cachedTokens, tokens), tokens.count - 1)
        guard cachedTokens.count + tokens.count - shared + Self.generationReserve <= context.contextSize else { return .noRoom }
        var reuse = min(commonPrefixLength(stagedTokens, tokens), tokens.count - 1)
        if stagedTokens.isEmpty || shared > reuse {
            context.clearSequence(stagingSequence)
            context.copySequence(Self.baseSequence, to: stagingSequence)
            stagedTokens = cachedTokens
            reuse = shared
        }
        if reuse < stagedTokens.count {
            if !context.removeTokens(sequence: stagingSequence, from: reuse) {
                context.clearSequence(stagingSequence)
                reuse = 0
            }
            stagedTokens.removeSubrange(reuse...)
        }
        hasStagedLogits = false
        let end = min(reuse + max(1, limit), tokens.count)
        let entries = (reuse..<end).map {
            DecodeEntry(token: tokens[$0], position: $0, sequence: stagingSequence, wantsLogits: $0 == tokens.count - 1)
        }
        do {
            try context.decode(entries)
        } catch {
            stagedTokens = Array(tokens.prefix(context.maxPosition(sequence: stagingSequence) + 1))
            throw error
        }
        stagedTokens.append(contentsOf: tokens[reuse..<end])
        guard end == tokens.count else { return .working }
        guard let logits = context.logits(at: -1) else { throw InferenceError.decodeFailed(-1) }
        _ = stagedLogits.update(fromContentsOf: UnsafeBufferPointer(start: logits, count: vocabulary.count))
        hasStagedLogits = true
        return .done
    }

    private func adoptStaged(ifCloserTo tokens: [Int32]) {
        guard !stagedTokens.isEmpty, commonPrefixLength(stagedTokens, tokens) > commonPrefixLength(cachedTokens, tokens) else { return }
        context.clearSequence(Self.baseSequence)
        context.copySequence(stagingSequence, to: Self.baseSequence)
        context.clearSequence(stagingSequence)
        cachedTokens = stagedTokens
        hasPromptLogits = hasStagedLogits
        if hasStagedLogits { _ = promptLogits.update(fromContentsOf: UnsafeBufferPointer(stagedLogits)) }
        stagedTokens = []
        hasStagedLogits = false
        rootVersion += 1
    }

    func firstToken(of word: String) -> Int32? {
        if let cached = firstTokens[word] { return cached }
        let token = vocabulary.tokenize(" " + word, addSpecial: false).first
        firstTokens[word] = token
        return token
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
