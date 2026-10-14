import Accelerate

struct TokenLogit: Equatable {
    var token: Int32
    var logit: Float
}

enum LogitMath {
    /// log(sum(exp(logits))), computed stably. `scratch` must hold `logits.count` floats.
    static func logSumExp(_ logits: UnsafeBufferPointer<Float>, scratch: UnsafeMutableBufferPointer<Float>) -> Float {
        guard let base = logits.baseAddress, let work = scratch.baseAddress, !logits.isEmpty else { return -.infinity }
        let count = vDSP_Length(logits.count)
        var maximum: Float = 0
        vDSP_maxv(base, 1, &maximum, count)
        guard maximum.isFinite else { return maximum }
        var shift = -maximum
        vDSP_vsadd(base, 1, &shift, work, 1, count)
        var n = Int32(logits.count)
        vvexpf(work, work, &n)
        var sum: Float = 0
        vDSP_sve(work, 1, &sum, count)
        return maximum + log(sum)
    }

    static func topK(_ logits: UnsafeBufferPointer<Float>, k: Int) -> [TokenLogit] {
        guard k > 0 else { return [] }
        var best: [TokenLogit] = []
        best.reserveCapacity(k + 1)
        var threshold = -Float.infinity
        for index in logits.indices {
            let value = logits[index]
            guard value > threshold else { continue }
            let position = best.firstIndex { value > $0.logit } ?? best.count
            best.insert(TokenLogit(token: Int32(index), logit: value), at: position)
            if best.count > k { best.removeLast() }
            if best.count == k { threshold = best[k - 1].logit }
        }
        return best
    }

    static func normalizedScore(logprob: Double, tokens: Int, lengthPenalty: Double) -> Double {
        logprob / pow(Double(max(tokens, 1)), lengthPenalty)
    }
}
