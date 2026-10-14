import Foundation
@testable import Inference

/// A word-bigram language model over a small vocabulary. Logits depend only on the token sequence, so a
/// search gives the same numbers however its decodes are batched.
struct ToyLanguage {
    static let followers: [String: [(String, Float)]] = [
        "i": [("saw", 5), ("ran", 3)],
        "saw": [("the", 5), ("a", 3)],
        "the": [("quick", 5), ("lazy", 4), ("cat", 2)],
        "a": [("red", 5), ("cat", 3)],
        "quick": [("brown", 6)],
        "brown": [("fox", 6)],
        "fox": [("jumps", 5), ("ran", 3)],
        "jumps": [("over", 6)],
        "over": [("the", 6)],
        "lazy": [("dog", 6)],
        "dog": [(".", 5), ("and", 3)],
        "cat": [("sat", 5), ("ran", 3)],
        "sat": [("on", 6)],
        "on": [("the", 6)],
        "red": [("car", 6)],
        "car": [(".", 4), ("and", 3)],
        "ran": [("away", 6)],
        "away": [(".", 6)],
        "and": [("then", 6)],
        "then": [("the", 4), ("ran", 3)],
        ".": [("</s>", 6)],
        // `space` is the lone space token, which real models also give some weight to after a word.
        "she": [(space, 6), ("said", 4)],
        "said": [("hi", 6)],
        "hi": [(".", 6)],
    ]
    static let space = "<space>"

    let pieces: [[UInt8]]
    let bos: Int32 = 0
    let eos: Int32 = 1
    private let ids: [String: Int32]

    init() {
        var pieces: [String] = ["<s>", "</s>", ".", "\n"]
        let words = Set(Self.followers.keys).union(Self.followers.values.flatMap { $0.map(\.0) }).subtracting([".", "</s>", Self.space]).sorted()
        pieces += words.map { " " + $0 } + words
        let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        pieces += letters.map { " " + $0 } + letters + [" "]
        var seen = Set<String>()
        pieces = pieces.filter { seen.insert($0).inserted }
        self.pieces = pieces.map { Array($0.utf8) }
        ids = Dictionary(uniqueKeysWithValues: pieces.enumerated().map { ($1, Int32($0)) })
    }

    func vocabulary() -> LlamaVocabulary {
        LlamaVocabulary(pieces: pieces, endOfGeneration: [eos], bos: bos) { text, addSpecial in
            self.tokenize(text, addSpecial: addSpecial)
        }
    }

    func tokenize(_ text: String, addSpecial: Bool) -> [Int32] {
        let bytes = Array(text.utf8)
        var tokens: [Int32] = addSpecial ? [bos] : []
        var index = 0
        while index < bytes.count {
            var best: (Int32, Int)?
            for (id, piece) in pieces.enumerated() where id > 1 && !piece.isEmpty && piece.count > (best?.1 ?? 0) {
                if bytes[index...].starts(with: piece) { best = (Int32(id), piece.count) }
            }
            guard let best else { break }
            tokens.append(best.0)
            index += best.1
        }
        return tokens
    }

    func logits(after tokens: [Int32]) -> [Float] {
        var row = [Float](repeating: -8, count: pieces.count)
        row[Int(eos)] = -6
        let text = String(decoding: tokens.filter { $0 != bos }.flatMap { pieces[Int($0)] }, as: UTF8.self)
        let last = text.hasSuffix(".") ? "." : text.split(separator: " ").last.map(String.init) ?? ""
        for (word, logit) in Self.followers[last] ?? [] {
            let piece = word == "." || word == "</s>" ? word : word == Self.space ? " " : " " + word
            if let id = ids[piece] { row[Int(id)] = logit }
        }
        return row
    }
}

final class FakeContext: DecodeContext, @unchecked Sendable {
    let language: ToyLanguage
    let batchCapacity = 512
    let contextSize = 4096
    private(set) var sequences: [Int32: [Int32]] = [:]
    private(set) var decodeCalls = 0
    private(set) var decodedTokens = 0
    private var rows: UnsafeMutablePointer<Float>
    private var rowCount = 0
    private var outputRows: [Int: Int] = [:]

    init(language: ToyLanguage) {
        self.language = language
        rows = .allocate(capacity: language.pieces.count * batchCapacity)
    }

    deinit { rows.deallocate() }

    var busySequences: Int { sequences.filter { $0.key != 0 && !$0.value.isEmpty }.count }

    func decode(_ entries: [DecodeEntry]) throws {
        decodeCalls += 1
        decodedTokens += entries.count
        rowCount = 0
        outputRows = [:]
        for (index, entry) in entries.enumerated() {
            var tokens = sequences[entry.sequence] ?? []
            precondition(tokens.count == entry.position, "sequence \(entry.sequence) holds \(tokens.count) tokens, decode at \(entry.position)")
            tokens.append(entry.token)
            sequences[entry.sequence] = tokens
            guard entry.wantsLogits else { continue }
            let row = language.logits(after: tokens)
            (rows + rowCount * row.count).update(from: row, count: row.count)
            outputRows[index] = rowCount
            rowCount += 1
        }
    }

    /// Like llama: a batch index, or outputs counted from the end when negative.
    func logits(at index: Int) -> UnsafeMutablePointer<Float>? {
        guard let resolved = index < 0 ? rowCount + index : outputRows[index], resolved >= 0, resolved < rowCount else { return nil }
        return rows + resolved * language.pieces.count
    }

    func removeTokens(sequence: Int32, from position: Int) -> Bool {
        sequences[sequence] = Array((sequences[sequence] ?? []).prefix(position))
        return true
    }

    func clearSequence(_ sequence: Int32) {
        sequences[sequence] = nil
    }

    func copySequence(_ source: Int32, to destination: Int32) {
        precondition((sequences[destination] ?? []).isEmpty, "copy into busy sequence \(destination)")
        sequences[destination] = sequences[source] ?? []
    }

    func maxPosition(sequence: Int32) -> Int {
        (sequences[sequence]?.count ?? 0) - 1
    }

    func clearAll() {
        sequences = [:]
    }
}

struct ToyEngine {
    let engine: CompletionEngine
    let context: FakeContext

    static func make(stepping: CompletionEngine.Stepping = .manual, sequences: Int = CompletionEngine.sequenceCount) async -> ToyEngine {
        let language = ToyLanguage()
        let context = FakeContext(language: language)
        let toy = ToyEngine(engine: CompletionEngine(stepping: stepping), context: context)
        await toy.engine.attach(Session(
            vocabulary: language.vocabulary(), context: context, maxBeams: CompletionEngine.maxBeams,
            sequences: sequences, rowSlots: BeamSearch.parkLimit
        ))
        return toy
    }

    func settle(_ request: CompletionRequest) async -> [SuggestionUpdate] {
        let subscription = engine.suggestions(for: request)
        var updates: [SuggestionUpdate] = []
        while let unit = await engine.runUnit() {
            updates += unit.publications.filter { $0.request == subscription.id }.map(\.update)
        }
        return updates
    }
}

extension CompletionRequest {
    static func toy(_ text: String, after: String = "", beams: Int = 6, reuses: Bool = true) -> CompletionRequest {
        let partial = String(text.reversed().prefix { $0.isLetter }.reversed())
        var tuning = SearchTuning()
        tuning.narrowAfterSteps = nil
        tuning.reusesBeams = reuses
        return CompletionRequest(
            prompt: String(text.dropLast(partial.count)), partialWord: partial, textAfter: after, maxWords: 4, beams: beams, tuning: tuning
        )
    }
}
