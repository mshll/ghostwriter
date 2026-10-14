import Foundation

public struct ContinuationScore: Sendable, Hashable {
    public var logprob: Double
    /// Characters of the scored text: the continuation plus any prompt characters sharing its first token.
    public var characters: Int
    public var tokens: Int

    public var bitsPerCharacter: Double { characters > 0 ? -logprob / log(2) / Double(characters) : 0 }
}

extension Session {
    func score(prompt: String, continuation: String, abort: AbortSignal) throws -> ContinuationScore {
        let promptTokens = vocabulary.tokenize(prompt, addSpecial: true)
        let fullTokens = vocabulary.tokenize(prompt + continuation, addSpecial: true)
        let shared = min(commonPrefixLength(promptTokens, fullTokens), fullTokens.count - 1)
        let scored = Array(fullTokens.dropFirst(shared))
        guard shared >= 1, !scored.isEmpty, scored.count <= context.batchCapacity else {
            return ContinuationScore(logprob: 0, characters: 0, tokens: 0)
        }
        var stats = GenerationStats()
        try prefill(Array(fullTokens.prefix(shared)), abort: abort, stats: &stats)

        guard let sequence = allocateSequence() else { throw InferenceError.decodeFailed(-1) }
        defer { releaseSequence(sequence) }
        context.copySequence(Self.baseSequence, to: sequence)
        let entries = scored.dropLast().enumerated().map { offset, token in
            DecodeEntry(token: token, position: promptLength + offset, sequence: sequence, wantsLogits: true)
        }
        if !entries.isEmpty { try context.decode(entries) }

        func logprob(_ token: Int32, in row: UnsafePointer<Float>) -> Double {
            let logits = UnsafeBufferPointer(start: row, count: vocabulary.count)
            return Double(row[Int(token)] - LogitMath.logSumExp(logits, scratch: scratch))
        }
        guard let first = promptLogits.baseAddress else { throw InferenceError.decodeFailed(-1) }
        var total = logprob(scored[0], in: first)
        for (offset, token) in scored.dropFirst().enumerated() {
            guard let row = context.logits(at: offset) else { throw InferenceError.decodeFailed(-1) }
            total += logprob(token, in: row)
        }
        let text = String(decoding: scored.flatMap { vocabulary.piece($0) }, as: UTF8.self)
        return ContinuationScore(logprob: total, characters: text.count, tokens: scored.count)
    }
}
