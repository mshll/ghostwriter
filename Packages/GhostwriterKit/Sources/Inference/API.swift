import Foundation
import GWCore

public struct EngineConfig: Sendable, Hashable {
    public var contextSize: Int = 4096
    public var batchSize: Int = 512
    public var microBatchSize: Int?
    public var threads: Int = 2
    public var batchThreads: Int = 4
    public var gpuLayers: Int = -1
    public var flashAttention: Bool = true
    /// Prompt tokens decoded per unit while staging a prompt (`CompletionEngine.stage`) as the user types (a
    /// request arrived within the last second). A keystroke waits for at most the unit in progress, since Metal
    /// does not stop a running decode; smaller units cost keystrokes less and stage more slowly. Idle, staging
    /// decodes 128 tokens per unit.
    public var stagingChunk: Int = 32

    public init() {}
}

public struct LoadedModelInfo: Sendable, Hashable {
    public var name: String
    public var parameterCount: Int64
    public var sizeBytes: Int64
    public var vocabSize: Int
}

/// Beam-search knobs; defaults come from gw-eval runs.
public struct SearchTuning: Sendable, Hashable {
    public var lengthPenalty: Double = 0.7
    public var probabilityFloor: Double = 0.05
    public var confidenceRatio: Double = 0
    public var midLineConfidenceRatio: Double = 0.7
    public var narrowAfterSteps: Int?
    public var narrowedStopProbability: Double = 0.3
    public var maxCandidates: Int = 6
    public var earlyStopMargin: Double? = 0
    public var midLineContextTokens: Int = 4
    public var blocksEchoes: Bool = true
    public var midLineCandidates: Int = 3
    public var midLineWordBonus: Double = 2
    public var midLineMargin: Double = 0
    public var reusesBeams = true

    public init() {}
}

public struct CompletionRequest: Sendable, Hashable {
    public enum Mode: Sendable, Hashable { case inline, draft }

    /// Full prompt; ends with the text before the caret minus `partialWord`.
    public var prompt: String
    public var partialWord: String
    public var textAfter: String
    public var maxWords: Int
    public var mode: Mode
    public var beams: Int
    public var topK: Int
    public var bias: TokenBias?
    public var tuning: SearchTuning
    public var stopStrings: [String]

    public init(
        prompt: String, partialWord: String = "", textAfter: String = "", maxWords: Int,
        mode: Mode = .inline, beams: Int = 6, topK: Int = 20, bias: TokenBias? = nil,
        tuning: SearchTuning = SearchTuning(), stopStrings: [String] = []
    ) {
        self.prompt = prompt
        self.partialWord = partialWord
        self.textAfter = textAfter
        self.maxWords = maxWords
        self.mode = mode
        self.beams = beams
        self.topK = topK
        self.bias = bias
        self.tuning = tuning
        self.stopStrings = stopStrings
    }
}

public struct TokenBias: Sendable, Hashable {
    public var followers: [String: [String: Double]]
    public var strength: Double

    public init(followers: [String: [String: Double]], strength: Double) {
        self.followers = followers
        self.strength = strength
    }
}

public struct Candidate: Sendable, Hashable {
    /// Text to insert at the caret (excludes the already-typed partial word).
    public var text: String
    public var score: Double

    public init(text: String, score: Double) {
        self.text = text
        self.score = score
    }
}

public struct SuggestionUpdate: Sendable, Hashable {
    public var candidates: [Candidate]
    public var isFinal: Bool
    public var milliseconds: Double
    public var reused: Bool
}

public struct SuggestionSubscription: Sendable {
    public let id: Int
    public let updates: AsyncStream<SuggestionUpdate>
}

public struct Publication: Sendable, Hashable {
    public var request: Int
    public var update: SuggestionUpdate
}

public struct EngineUnit: Sendable {
    public var milliseconds: Double
    public var publications: [Publication]
    public var staged = false
}

public struct GenerationStats: Sendable, Hashable {
    public var promptTokens = 0
    public var reusedTokens = 0
    public var tokenizeMilliseconds = 0.0
    public var prefillMilliseconds = 0.0
    public var steps = 0
    public var searchMilliseconds = 0.0
    public var rerankMilliseconds = 0.0
    public var totalMilliseconds = 0.0

    public init() {}
}

public enum InferenceError: Error, LocalizedError {
    case modelLoadFailed(String)
    case unsupportedModel(String)
    case contextCreationFailed
    case notLoaded
    case decodeFailed(Int32)
    case checksumMismatch(expected: String, actual: String)
    case downloadFailed(String)
    case alreadyDownloading(String)
    case insufficientSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let fileName): "Could not load the model \(fileName)."
        case .unsupportedModel(let reason): "This model is not supported: \(reason)."
        case .contextCreationFailed: "Could not create an inference context."
        case .notLoaded: "No model is loaded."
        case .decodeFailed(let code): "Decoding failed (code \(code))."
        case .checksumMismatch(let expected, let actual): "Checksum mismatch: expected \(expected), got \(actual)."
        case .downloadFailed(let reason): "Download failed: \(reason)."
        case .alreadyDownloading(let name): "\(name) is already downloading."
        case .insufficientSpace(let needed, let available):
            "Not enough free disk space: the download needs \(Self.bytes(needed)) and \(Self.bytes(available)) is available."
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
