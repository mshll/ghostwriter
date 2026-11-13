import Foundation
import Inference

/// Decode time against batch size after each row's prompt, as medians over the repeats and rows.
func measureDecodeCurve(_ options: Options, set: URL) async throws {
    let rows = try loadRows(from: set, limit: options.limit ?? 3)
    let harness = try await Harness.load(options)
    var timings: [DecodeTiming] = []
    for row in rows {
        let request = try harness.request(for: row, before: row.before)
        await harness.engine.clearCache()
        timings += try await harness.engine.decodeTimings(
            prompt: request.prompt, maxTokens: options.curveTokens, repeats: options.curveRepeats, shapes: DecodeShape.allCases
        )
    }
    print("decode milliseconds by batch size: \(rows.count) prompts, \(options.curveRepeats) repeats each")
    print("tokens " + DecodeShape.allCases.map { "\($0.rawValue) p50".leftPadded(11) + "p90".leftPadded(7) }.joined())
    for tokens in 1...options.curveTokens {
        let cells = DecodeShape.allCases.map { shape in
            let values = timings.filter { $0.shape == shape && $0.tokens == tokens }.map(\.milliseconds)
            return format(Metrics.percentile(values, 0.5)).leftPadded(11) + format(Metrics.percentile(values, 0.9)).leftPadded(7)
        }
        print(String(tokens).leftPadded(6) + cells.joined())
    }
}
