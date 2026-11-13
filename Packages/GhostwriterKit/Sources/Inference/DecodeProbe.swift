import Foundation

/// How the tokens of one probe decode are spread over sequences.
public enum DecodeShape: String, Sendable, CaseIterable {
    /// One token in each of its own sequences, like a beam step.
    case beams
    /// Consecutive tokens of a single sequence, like one rerank sequence.
    case chain
    /// Up to six beam tokens, then the rest as chains in up to three more sequences, like a beam step that
    /// carries a mid-line rerank.
    case mixed
}

public struct DecodeTiming: Sendable, Hashable {
    public var shape: DecodeShape
    public var tokens: Int
    public var milliseconds: Double
}

extension DecodeShape {
    /// The sequence index (0-based among the probe's sequences) and position offset of each token.
    func layout(_ tokens: Int) -> [(sequence: Int, offset: Int)] {
        switch self {
        case .beams:
            return (0..<tokens).map { ($0, 0) }
        case .chain:
            return (0..<tokens).map { (0, $0) }
        case .mixed:
            let beams = min(tokens, 6)
            let rest = tokens - beams
            let chains = min(max(rest, 0), 3)
            var layout = (0..<beams).map { (sequence: $0, offset: 0) }
            for chain in 0..<chains {
                let length = rest / chains + (chain < rest % chains ? 1 : 0)
                layout += (0..<length).map { (beams + chain, $0) }
            }
            return layout
        }
    }
}

extension Session {
    /// Times decodes of 1 through `maxTokens` tokens after the cached prompt, in shuffled order, `repeats` times.
    func decodeTimings(maxTokens: Int, repeats: Int, shapes: [DecodeShape]) throws -> [DecodeTiming] {
        let token = vocabulary.tokenize(" the", addSpecial: false).first ?? vocabulary.bos
        var timings: [DecodeTiming] = []
        var generator = SystemRandomNumberGenerator()
        for round in 0...repeats {
            let trials = shapes.flatMap { shape in (1...maxTokens).map { (shape, $0) } }.shuffled(using: &generator)
            for (shape, tokens) in trials {
                let layout = shape.layout(tokens)
                let count = (layout.map(\.sequence).max() ?? 0) + 1
                var ids: [Int32] = []
                defer { ids.forEach(releaseSequence) }
                for _ in 0..<count {
                    guard let sequence = allocateSequence() else { throw InferenceError.decodeFailed(-1) }
                    context.copySequence(Self.baseSequence, to: sequence)
                    ids.append(sequence)
                }
                let entries = layout.map {
                    DecodeEntry(token: token, position: promptLength + $0.offset, sequence: ids[$0.sequence], wantsLogits: true)
                }
                let started = ContinuousClock.now
                try context.decode(entries)
                _ = context.logits(at: entries.count - 1)
                let elapsed = started.duration(to: .now).milliseconds
                if round > 0 { timings.append(DecodeTiming(shape: shape, tokens: tokens, milliseconds: elapsed)) }
            }
        }
        return timings
    }
}
