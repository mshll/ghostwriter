import Foundation
import Inference

private let typedAfterFocus = 5

/// The first request after each model load against the same request repeated with an empty cache, which isolates
/// what a load leaves for the first decode to do (GPU pipeline setup, buffer allocation).
func measureFirstRequest(_ options: Options, set: URL) async throws {
    let rows = try loadRows(from: set, limit: options.limit ?? 5)
    guard !rows.isEmpty else { throw UsageError("no rows in \(set.path)") }
    let harness = try await Harness.load(options)
    var first: [GenerationStats] = []
    var repeated: [GenerationStats] = []
    print("load  warm-up  stage   first: total prefill search   repeat: total prefill search  (ms)")
    for (index, row) in rows.enumerated() {
        if index > 0 {
            await harness.engine.unload()
            let start = ContinuousClock.now
            _ = try await harness.engine.load(modelAt: options.model, config: options.engine)
            print("reload \(format(milliseconds(since: start), 0)) ms")
        }
        var warmUp: Double?
        if options.warmUp {
            let start = ContinuousClock.now
            await harness.engine.warmUp()
            warmUp = milliseconds(since: start)
        }
        var stage: Double?
        if options.staged {
            let focused = try harness.request(for: row, before: String(row.before.dropLast(typedAfterFocus)))
            let start = ContinuousClock.now
            _ = await harness.engine.stage(prompt: focused.prompt)
            stage = milliseconds(since: start)
        }
        let request = try harness.request(for: row, before: row.before)
        let cold = try await harness.timed(request).stats
        await harness.engine.clearCache()
        let again = try await harness.timed(request).stats
        first.append(cold)
        repeated.append(again)
        print(
            String(index + 1).leftPadded(4), format(warmUp, 0).leftPadded(9), format(stage, 0).leftPadded(6),
            format(cold.totalMilliseconds, 0).leftPadded(14), format(cold.prefillMilliseconds, 0).leftPadded(7),
            format(cold.searchMilliseconds, 0).leftPadded(6),
            format(again.totalMilliseconds, 0).leftPadded(15), format(again.prefillMilliseconds, 0).leftPadded(7),
            format(again.searchMilliseconds, 0).leftPadded(6), "  \(cold.promptTokens) prompt tokens"
        )
    }
    let penalty = zip(first, repeated).map { $0.totalMilliseconds - $1.totalMilliseconds }
    print("first request minus repeat: p50 \(format(Metrics.percentile(penalty, 0.5), 0)) ms, max \(format(penalty.max(), 0)) ms over \(penalty.count) loads")
}
