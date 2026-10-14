import Foundation
import Inference
import Synchronization

enum SwapMode: String {
    case none
    case direct
    case staged
}

struct SwapResult: Encodable {
    var id: String
    var midLine: Bool
    var waits: [Double] = []
    var censored: [Bool] = []
    var during: [Bool] = []
    var swapMilliseconds: Double?
    var keystrokes = 0
    var buildMilliseconds: [Double] = []
}

func simulateSwap(_ options: Options, set: URL, mode: SwapMode) async throws {
    let rows = try loadRows(from: set, limit: nil).filter { $0.truth != nil && ($0.screen?.count ?? 0) >= 1000 }
    let sample = Array(rows.prefix(options.limit ?? 40))
    let harness = try await Harness.load(options)
    let interval = 1000 / (options.typingSpeed ?? 6)
    var results: [SwapResult] = []
    let start = ContinuousClock.now
    for row in sample {
        let result = try await SwapRow(row: row, harness: harness, interval: interval, mode: mode, swapAt: options.swapAt).run()
        results.append(result)
        if options.verbose {
            print(result.id, "swap \(result.swapMilliseconds.map { format($0, 0) } ?? "-") ms", "waits \(zip(result.waits, result.during).map { "\(Int($0))\($1 ? "*" : "")" })")
        }
    }
    print("swapped screen text in \(results.count) rows in \(format(milliseconds(since: start) / 1000)) s, mode \(mode), staging chunk \(options.engine.stagingChunk) tokens, \(format(1000 / interval)) characters per second, swap at keystroke \(options.swapAt)")
    func line(_ waits: [Double], _ censored: [Bool]) -> String {
        let gaps = waits.filter { $0 > 0 }
        return [
            String(waits.count).leftPadded(6),
            percent(Double(gaps.count) / Double(max(waits.count, 1))).leftPadded(7),
            format(Metrics.percentile(gaps, 0.5), 0).leftPadded(7),
            format(Metrics.percentile(gaps, 0.95), 0).leftPadded(7),
            format(gaps.max() ?? 0, 0).leftPadded(6),
            percent(1 - Double(waits.filter { $0 > 100 }.count) / Double(max(waits.count, 1))).leftPadded(9),
            percent(1 - Double(waits.filter { $0 > interval }.count) / Double(max(waits.count, 1))).leftPadded(9),
            String(censored.filter { $0 }.count).leftPadded(9),
        ].joined(separator: " ")
    }
    print("\nkeys    count    gaps  gap50   gap95    max  ready100  in-time  censored")
    let during = results.flatMap { zip(zip($0.waits, $0.censored), $0.during).filter(\.1).map(\.0) }
    let after = results.flatMap { zip(zip($0.waits, $0.censored), $0.during).filter { !$0.1 }.map(\.0) }
    print("during  " + line(during.map(\.0), during.map(\.1)))
    print("after   " + line(after.map(\.0), after.map(\.1)))
    print("all     " + line(results.flatMap(\.waits), results.flatMap(\.censored)))
    let swaps = results.compactMap(\.swapMilliseconds)
    let builds = results.flatMap(\.buildMilliseconds)
    print("request building p50 \(format(Metrics.percentile(builds, 0.5), 2)) ms, p95 \(format(Metrics.percentile(builds, 0.95), 2)) ms over \(builds.count) keystrokes")
    print("new prompt ready during the row in \(swaps.count) of \(results.count) rows: p50 \(format(Metrics.percentile(swaps, 0.5), 0)) ms, p95 \(format(Metrics.percentile(swaps, 0.95), 0)) ms after the text landed")
    if let json = options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: json)
        print("wrote \(json.path)")
    }
}

private struct SwapRow {
    let row: Row
    let harness: Harness
    let interval: Double
    let mode: SwapMode
    let swapAt: Int

    private struct Shown {
        var time: Double
        var typed: Int
        var candidates: [String]
        var fromNew: Bool
    }

    func run() async throws -> SwapResult {
        let engine = harness.engine
        let target = Array(folded(row.truth ?? ""))
        let screen = row.screen ?? ""
        func request(typed: Int, new: Bool) -> CompletionRequest {
            harness.request(for: row, before: row.before + String(target[..<typed]), screenText: new ? screen : "")
        }
        await engine.clearCache()
        for await _ in engine.suggestions(for: request(typed: 0, new: false)).updates {}

        let shown = Mutex<[Shown]>([])
        let ready = Mutex<Double?>(nil)
        let start = ContinuousClock.now
        var listeners: [Task<Void, Never>] = []
        var staging: Task<Void, Never>?
        var swapStart: Double?
        var buildMilliseconds: [Double] = []
        for typed in 1...target.count {
            try await Task.sleep(until: start + .milliseconds(Double(typed) * interval), clock: .continuous)
            if typed == swapAt, mode != .none {
                swapStart = milliseconds(since: start)
                if mode == .staged {
                    let prompt = request(typed: typed, new: true).prompt
                    staging = Task {
                        if await engine.stage(prompt: prompt) { ready.withLock { $0 = milliseconds(since: start) } }
                    }
                }
            }
            let new = switch mode {
            case .none: false
            case .direct: swapStart != nil
            case .staged: ready.withLock { $0 != nil }
            }
            let building = ContinuousClock.now
            let next = request(typed: typed, new: new)
            buildMilliseconds.append(milliseconds(since: building))
            let subscription = engine.suggestions(for: next)
            listeners.append(Task {
                for await update in subscription.updates where !update.candidates.isEmpty {
                    let candidates = update.candidates.map { folded($0.text) }
                    shown.withLock { $0.append(Shown(time: milliseconds(since: start), typed: typed, candidates: candidates, fromNew: new)) }
                }
            })
        }
        let end = Double(target.count + 1) * interval
        try await Task.sleep(until: start + .milliseconds(end), clock: .continuous)
        engine.cancel()
        for listener in listeners { listener.cancel() }
        _ = await staging?.value

        var result = SwapResult(id: row.id, midLine: !(row.after ?? "").isEmpty, buildMilliseconds: buildMilliseconds)
        let events = shown.withLock { $0 }.filter { $0.time < end }.sorted { $0.time < $1.time }
        let readyAt: Double? = switch mode {
        case .none: nil
        case .direct: events.first { $0.fromNew }?.time
        case .staged: ready.withLock { $0 }.flatMap { $0 < end ? $0 : nil }
        }
        if let swapStart, let readyAt { result.swapMilliseconds = readyAt - swapStart }

        var visible: [String] = []
        var next = 0
        for typed in 1...target.count {
            let time = Double(typed) * interval
            while next < events.count, events[next].time < time {
                let event = events[next]
                next += 1
                guard event.typed <= typed - 1 else { continue }
                let fitting = advance(event.candidates, by: String(target[event.typed..<(typed - 1)]))
                if visible.isEmpty {
                    visible = fitting
                } else if let extended = fitting.first(where: { $0.hasPrefix(visible[0]) }) {
                    visible = [extended]
                }
            }
            visible = advance(visible, by: String(target[typed - 1]))
            guard typed >= swapAt, typed < target.count else { continue }
            result.keystrokes += 1
            result.during.append(readyAt.map { time < $0 } ?? (swapStart != nil))
            if !visible.isEmpty {
                result.waits.append(0)
                result.censored.append(false)
                continue
            }
            var wait: Double?
            for event in events[next...] {
                let typedThen = min(target.count, Int(event.time / interval))
                guard event.typed <= typedThen, typedThen < target.count else { continue }
                if !advance(event.candidates, by: String(target[event.typed..<typedThen])).isEmpty {
                    wait = event.time - time
                    break
                }
            }
            result.waits.append(wait ?? (end - time))
            result.censored.append(wait == nil)
        }
        return result
    }
}
