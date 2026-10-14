import Foundation

struct MidLinePlan {
    var candidates: [Candidate]
    var sequences: [[Int32]]
}

struct RerankBatch {
    var sequences: [[Int32]]
    var ids: [Int32]
    var entries: [DecodeEntry]
    var rows: [[Int]]
}

extension Session {
    func rerankMidLine(
        _ candidates: [Candidate], required: [UInt8], textAfter: String, tuning: SearchTuning, totals: inout [[Int32]: Double]
    ) throws -> [Candidate] {
        guard let plan = midLinePlan(candidates, required: required, textAfter: textAfter, tuning: tuning) else { return candidates }
        guard !plan.candidates.isEmpty else { return [] }
        let missing = unscored(plan, in: totals)
        if !missing.isEmpty {
            guard let batch = rerankBatch(missing, room: context.batchCapacity) else { return plan.candidates }
            do {
                try context.decode(batch.entries)
            } catch {
                discard(batch)
                throw error
            }
            try collect(batch, offset: 0, into: &totals)
        }
        return kept(plan, totals: totals, tuning: tuning)
    }

    func midLinePlan(_ candidates: [Candidate], required: [UInt8], textAfter: String, tuning: SearchTuning) -> MidLinePlan? {
        guard !vocabulary.tokenize(textAfter, addSpecial: false).isEmpty else { return nil }
        let candidates = candidates
            .filter { !TextRules.clashes(insertion: $0.text, before: textAfter) }
            .prefix(max(tuning.midLineCandidates, 1))
            .map { Candidate(text: TextRules.insertion($0.text, before: textAfter), score: $0.score) }
        let required = String(decoding: required, as: UTF8.self)
        let afterTokens = max(tuning.midLineContextTokens, 1)
        let sequences = ([""] + candidates.map(\.text)).map { option in
            let head = vocabulary.tokenize(TextRules.trimmingTrailingWhitespace(required + option), addSpecial: false).count
            return Array(vocabulary.tokenize(required + option + textAfter, addSpecial: false).prefix(head + afterTokens))
        }
        return MidLinePlan(candidates: candidates, sequences: sequences)
    }

    func unscored(_ plan: MidLinePlan, in totals: [[Int32]: Double]) -> [[Int32]] {
        var missing: [[Int32]] = []
        for tokens in plan.sequences where !tokens.isEmpty && totals[tokens] == nil && !missing.contains(tokens) {
            missing.append(tokens)
        }
        return missing
    }

    func kept(_ plan: MidLinePlan, totals: [[Int32]: Double], tuning: SearchTuning) -> [Candidate] {
        guard let emptySequence = plan.sequences.first, let empty = totals[emptySequence] else { return [] }
        return zip(plan.candidates, plan.sequences.dropFirst())
            .compactMap { candidate, tokens in
                guard let total = totals[tokens] else { return nil }
                let gain = total + tuning.midLineWordBonus * TextRules.wordUnits(candidate.text) - empty
                return gain > tuning.midLineMargin ? Candidate(text: candidate.text, score: gain) : nil
            }
            .sorted { $0.score > $1.score }
    }

    func rerankBatch(_ sequences: [[Int32]], room: Int) -> RerankBatch? {
        guard !sequences.isEmpty, sequences.count <= freeSequenceCount,
              sequences.map({ max($0.count - 1, 0) }).reduce(0, +) <= room else { return nil }
        var batch = RerankBatch(sequences: sequences, ids: [], entries: [], rows: [])
        for tokens in sequences {
            guard let sequence = allocateSequence() else {
                discard(batch)
                return nil
            }
            context.copySequence(Self.baseSequence, to: sequence)
            batch.ids.append(sequence)
            var rows: [Int] = []
            for (offset, token) in tokens.dropLast().enumerated() {
                rows.append(batch.entries.count)
                batch.entries.append(DecodeEntry(token: token, position: promptLength + offset, sequence: sequence, wantsLogits: true))
            }
            batch.rows.append(rows)
        }
        return batch
    }

    func collect(_ batch: RerankBatch, offset: Int, into totals: inout [[Int32]: Double]) throws {
        defer { discard(batch) }
        let promptNormalizer = LogitMath.logSumExp(UnsafeBufferPointer(promptLogits), scratch: scratch)
        for (index, tokens) in batch.sequences.enumerated() {
            var total = Double(promptLogits[Int(tokens[0])] - promptNormalizer)
            for (position, token) in tokens.dropFirst().enumerated() {
                guard let row = context.logits(at: offset + batch.rows[index][position]) else { throw InferenceError.decodeFailed(-1) }
                let normalizer = LogitMath.logSumExp(UnsafeBufferPointer(start: row, count: vocabulary.count), scratch: scratch)
                total += Double(row[Int(token)] - normalizer)
            }
            totals[tokens] = total
        }
    }

    func discard(_ batch: RerankBatch) {
        batch.ids.forEach(releaseSequence)
    }
}
