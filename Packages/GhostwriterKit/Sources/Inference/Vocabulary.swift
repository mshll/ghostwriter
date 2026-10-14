import Foundation
import GWCore
import llama

/// Tokenizer plus per-token piece tables. Immutable after init and llama's tokenizer is thread-safe,
/// so one instance is shared by the engine and by prompt budgeting on other threads.
final class LlamaVocabulary: TokenCounting, @unchecked Sendable {
    let model: LlamaModel?
    let count: Int
    let bos: Int32
    private let bytes: [UInt8]
    private let offsets: [Int32]
    private let flags: [UInt8]
    private let sorted: [Int32]
    private let tokenizer: (String, Bool) -> [Int32]

    private static let endOfGeneration: UInt8 = 1
    private static let banned: UInt8 = 2

    convenience init(model: LlamaModel) {
        let vocab = model.vocab
        let count = Int(llama_vocab_n_tokens(vocab))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count * 8)
        var offsets = [Int32](repeating: 0, count: count + 1)
        var flags = [UInt8](repeating: 0, count: count)
        let hidden = LLAMA_TOKEN_ATTR_UNKNOWN.rawValue | LLAMA_TOKEN_ATTR_CONTROL.rawValue | LLAMA_TOKEN_ATTR_UNUSED.rawValue
            | LLAMA_TOKEN_ATTR_USER_DEFINED.rawValue
        var buffer = [CChar](repeating: 0, count: 256)
        for token in 0..<count {
            let id = Int32(token)
            var length = llama_token_to_piece(vocab, id, &buffer, Int32(buffer.count), 0, false)
            if length < 0 {
                buffer = [CChar](repeating: 0, count: Int(-length))
                length = llama_token_to_piece(vocab, id, &buffer, Int32(buffer.count), 0, false)
            }
            if length > 0 {
                buffer.withUnsafeBytes { bytes.append(contentsOf: $0.prefix(Int(length))) }
            }
            offsets[token + 1] = Int32(bytes.count)
            if llama_vocab_is_eog(vocab, id) {
                flags[token] = Self.endOfGeneration
            } else if llama_vocab_get_attr(vocab, id).rawValue & hidden != 0 || length <= 0
                || Self.isPlaceholder(bytes[Int(offsets[token])...])
            {
                flags[token] = Self.banned
            }
        }
        self.init(bytes: bytes, offsets: offsets, flags: flags, bos: llama_vocab_bos(vocab), model: model) { text, addSpecial in
            let length = Int32(text.utf8.count)
            var tokens = [Int32](repeating: 0, count: Int(length) + 8)
            var produced = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addSpecial, false)
            if produced < 0, produced != Int32.min {
                tokens = [Int32](repeating: 0, count: Int(-produced))
                produced = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addSpecial, false)
            }
            return Array(tokens.prefix(Int(max(produced, 0))))
        }
    }

    convenience init(pieces: [[UInt8]], endOfGeneration: Set<Int32>, bos: Int32, tokenize: @escaping (String, Bool) -> [Int32]) {
        var bytes: [UInt8] = []
        var offsets: [Int32] = [0]
        for piece in pieces {
            bytes += piece
            offsets.append(Int32(bytes.count))
        }
        let flags = pieces.indices.map { id -> UInt8 in
            if endOfGeneration.contains(Int32(id)) { return Self.endOfGeneration }
            return pieces[id].isEmpty || Int32(id) == bos ? Self.banned : 0
        }
        self.init(bytes: bytes, offsets: offsets, flags: flags, bos: bos, model: nil, tokenize: tokenize)
    }

    private init(
        bytes: [UInt8], offsets: [Int32], flags: [UInt8], bos: Int32, model: LlamaModel?,
        tokenize: @escaping (String, Bool) -> [Int32]
    ) {
        let count = flags.count
        let selectable = (0..<count).filter { flags[$0] == 0 }.map { Int32($0) }
        sorted = bytes.withUnsafeBufferPointer { pieces in
            offsets.withUnsafeBufferPointer { ends in
                selectable.sorted { Self.compare(pieces, ends, $0, $1) < 0 }
            }
        }
        self.count = count
        self.bos = bos
        self.bytes = bytes
        self.offsets = offsets
        self.flags = flags
        self.model = model
        tokenizer = tokenize
    }

    func countTokens(_ text: String) -> Int {
        tokenize(text, addSpecial: false).count
    }

    func tokenize(_ text: String, addSpecial: Bool) -> [Int32] {
        tokenizer(text, addSpecial)
    }

    func piece(_ token: Int32) -> ArraySlice<UInt8> {
        bytes[Int(offsets[Int(token)])..<Int(offsets[Int(token) + 1])]
    }

    func pieceText(_ token: Int32) -> String {
        String(decoding: piece(token), as: UTF8.self)
    }

    func isEndOfGeneration(_ token: Int32) -> Bool { flags[Int(token)] == Self.endOfGeneration }
    func isBanned(_ token: Int32) -> Bool { flags[Int(token)] == Self.banned }

    func tokens(satisfying required: [UInt8], limit: Int) -> [Int32]? {
        guard !required.isEmpty else { return nil }
        let longer = range(of: required[...], prefixOnly: true)
        guard longer.count <= limit else { return nil }
        var result = Array(sorted[longer])
        for length in 1..<required.count {
            result += sorted[range(of: required.prefix(length), prefixOnly: false)]
        }
        return result
    }

    private func range(of key: ArraySlice<UInt8>, prefixOnly: Bool) -> Range<Int> {
        func order(_ token: Int32) -> Int {
            let piece = self.piece(token)
            let compared = prefixOnly ? piece.prefix(key.count) : piece
            if compared.elementsEqual(key) { return 0 }
            return compared.lexicographicallyPrecedes(key) ? -1 : 1
        }
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if order(sorted[mid]) < 0 { low = mid + 1 } else { high = mid }
        }
        let start = low
        high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if order(sorted[mid]) <= 0 { low = mid + 1 } else { high = mid }
        }
        return start..<low
    }

    /// Reserved `<unusedN>` slots that some GGUFs mark as normal text.
    private static func isPlaceholder(_ piece: ArraySlice<UInt8>) -> Bool {
        let prefix = Array("<unused".utf8)
        guard piece.starts(with: prefix), piece.last == UInt8(ascii: ">") else { return false }
        let digits = piece.dropFirst(prefix.count).dropLast()
        return !digits.isEmpty && digits.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    private static func compare(
        _ pieces: UnsafeBufferPointer<UInt8>, _ offsets: UnsafeBufferPointer<Int32>, _ lhs: Int32, _ rhs: Int32
    ) -> Int32 {
        let lhsStart = Int(offsets[Int(lhs)]), lhsCount = Int(offsets[Int(lhs) + 1]) - lhsStart
        let rhsStart = Int(offsets[Int(rhs)]), rhsCount = Int(offsets[Int(rhs) + 1]) - rhsStart
        guard let base = pieces.baseAddress else { return 0 }
        let shared = memcmp(base + lhsStart, base + rhsStart, min(lhsCount, rhsCount))
        if shared != 0 { return shared }
        return Int32(lhsCount - rhsCount)
    }
}
