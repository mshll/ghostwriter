import Foundation
import Inference
import Input

struct ClockedResult: Encodable {
    var id: String
    var lang: String
    var kind: String?
    var midLine: Bool
    var characters: Int
    var keystrokes: Int
    var shown: Int
    var used: Int
    var shownReused: Int
    var replaced = 0
    var replacedMilliseconds: [Double] = []
    var words: [Int] = []
    var badShown = 0
    var wordsSeen: [Int] = []
    var acceptedWords: [Int] = []
    var acceptedInFull: [Bool] = []
    var waits: [Double] = []
    var censored: [Bool] = []
    var busy: Double
    var elapsed: Double
    var units: Int
    var requests: Int
}

func simulateClocked(_ options: Options, set: URL, mode: EngineMode) async throws {
    let rows = try loadRows(from: set, limit: options.limit).filter { $0.truth != nil }
    var harness = try await Harness.load(options, stepping: .manual)
    harness.options.tuning.reusesBeams = mode != .oneshot
    let interval = options.typingSpeed.map { 1000 / $0 }
    var results: [ClockedResult] = []
    let start = ContinuousClock.now
    for row in rows {
        results.append(try await ClockedRow(row: row, harness: harness, interval: interval, mode: mode).run())
        if options.verbose, let result = results.last {
            print(result.id, result.lang, "saved \(result.characters - result.keystrokes)/\(result.characters)", "shown \(result.shown) used \(result.used)", "waits \(result.waits.map { Int($0) })")
        }
    }
    print("simulated \(results.count) rows in \(format(milliseconds(since: start) / 1000)) s, engine \(mode), " + (options.typingSpeed.map { "\(format($0)) characters per second" } ?? "no clock"))
    func line(_ members: [ClockedResult]) -> String {
        let characters = members.map(\.characters).reduce(0, +)
        let keystrokes = members.map(\.keystrokes).reduce(0, +)
        let shown = members.map(\.shown).reduce(0, +)
        let words = members.flatMap(\.wordsSeen)
        let waits = members.flatMap(\.waits)
        let late = interval.map { limit in Double(waits.filter { $0 > limit }.count) / Double(max(waits.count, 1)) }
        let ready100 = 1 - Double(waits.filter { $0 > 100 }.count) / Double(max(keystrokes, 1))
        let busy = members.map(\.busy).reduce(0, +) / max(members.map(\.elapsed).reduce(0, +), 1)
        let bad = Double(members.map(\.badShown).reduce(0, +)) / Double(max(shown, 1))
        return [
            String(members.count).leftPadded(5),
            percent(Double(characters - keystrokes) / Double(max(characters, 1))).leftPadded(7),
            percent(Double(members.map(\.used).reduce(0, +)) / Double(max(shown, 1))).leftPadded(7),
            format(Double(words.reduce(0, +)) / Double(max(words.count, 1)), 2).leftPadded(6),
            percent(Double(words.filter { $0 == 1 }.count) / Double(max(words.count, 1))).leftPadded(7),
            percent(Double(waits.count) / Double(max(keystrokes, 1))).leftPadded(7),
            format(Metrics.percentile(waits, 0.5), 0).leftPadded(6),
            format(Metrics.percentile(waits, 0.95), 0).leftPadded(6),
            (late.map(percent) ?? "-").leftPadded(7),
            percent(ready100).leftPadded(8),
            percent(interval == nil ? nil : busy).leftPadded(7),
            percent(bad).leftPadded(6),
            format(100 * Double(members.map(\.replaced).reduce(0, +)) / Double(max(keystrokes, 1)), 2).leftPadded(9),
        ].joined(separator: " ")
    }
    let columns = " rows   saved  useful  words  single    gaps  wait50 wait95    late  ready100    busy    bad  flicker%"
    printGroups("lang", results, key: \.lang, columns: columns, line: line)
    printGroups("kind", results, key: { $0.midLine ? "midline" : "lineend" }, columns: columns, line: line)
    if let json = options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: json)
        print("wrote \(json.path)")
    }
}

enum EngineMode: String {
    case continuous
    case economy
    case oneshot
}

private struct ClockedRow {
    let row: Row
    let harness: Harness
    let interval: Double?
    let mode: EngineMode

    private var engine: CompletionEngine { harness.engine }

    func run() async throws -> ClockedResult {
        let target = Array(folded(row.truth ?? ""))
        var result = ClockedResult(
            id: row.id, lang: language(of: row), kind: row.kind, midLine: !(row.after ?? "").isEmpty, characters: target.count,
            keystrokes: 0, shown: 0, used: 0, shownReused: 0, busy: 0, elapsed: 0, units: 0, requests: 0
        )
        await engine.clearCache()
        _ = engine.suggestions(for: harness.request(for: row, before: String(row.before.dropLast())))
        while await engine.runUnit() != nil {}

        var typed = 0
        var visible: [String] = []
        var visibleUsed = false
        var visibleFresh = false
        var visibleBad = false
        var visibleDrawn = false
        let after = String((row.after ?? "").prefix { !$0.isNewline })
        func checkVisible() {
            guard !visibleBad, let best = visible.first else { return }
            if Metrics.isLonePunctuation(best) || (!after.isEmpty && Metrics.breaksLine(completion: best, after: after)) {
                visibleBad = true
                result.badShown += 1
            }
        }
        var requests: [Int: (typed: Int, at: Double)] = [:]
        var inFlight: Int?
        var followUp = false
        var openWaits: [Double] = []
        var pending: [(time: Double, publication: Publication)] = []
        var clock = 0.0
        var nextKeystroke = interval ?? 0
        let readLag = interval == nil || mode == .oneshot ? 0 : harness.options.readLag
        var nextRead = 0.0
        var readSubmits = false

        var latest: Int?
        var settles: [(time: Double, publication: Publication)] = []

        func submit(at time: Double) {
            let subscription = engine.suggestions(for: harness.request(for: row, before: row.before + String(target[..<typed])))
            requests[subscription.id] = (typed, time)
            latest = subscription.id
            inFlight = subscription.id
            result.requests += 1
        }

        func apply(_ publication: Publication, at time: Double) {
            guard let issued = requests[publication.request] else { return }
            if publication.update.isFinal, inFlight == publication.request { inFlight = nil }
            let typedSince = String(target[issued.typed..<typed])
            let candidates = advance(publication.update.candidates.map { folded($0.text) }, by: typedSince)
            if candidates.isEmpty {
                if mode == .oneshot, visible.isEmpty, inFlight == nil, followUp || typed > issued.typed {
                    followUp = false
                    submit(at: time)
                }
                return
            }
            var settled = false
            if publication.update.isFinal, !result.midLine, let settle = harness.options.settle {
                settled = time - issued.at >= settle
                if !settled { settles.append((issued.at + settle, publication)) }
            }
            let drawn = time >= nextRead || (visibleDrawn && !visible.isEmpty)
            let merged = ShownSuggestion.merge(shown: visible, drawn: drawn, update: candidates, settled: settled)
            let replaces = drawn && visible.first.map { !merged[0].hasPrefix($0) } ?? false
            if visible.isEmpty || replaces {
                visibleDrawn = drawn
                visibleFresh = true
                followUp = false
                visible = merged
                visibleUsed = false
                visibleBad = false
                checkVisible()
                result.shown += 1
                if replaces {
                    result.replaced += 1
                    result.replacedMilliseconds.append(time - issued.at)
                }
                if publication.update.reused { result.shownReused += 1 }
                result.words.append(Metrics.units(merged[0]).count)
                result.acceptedWords.append(0)
                result.acceptedInFull.append(false)
                for opened in openWaits {
                    result.waits.append(max(time, nextRead) - opened)
                    result.censored.append(false)
                }
                openWaits = []
            } else {
                if !drawn, visibleBad {
                    visibleBad = false
                    result.badShown -= 1
                }
                visible = merged
                checkVisible()
            }
        }

        func deliver(until time: Double) {
            let settled = settles.filter { $0.time <= time && $0.publication.request == latest }
            settles.removeAll { $0.time <= time || $0.publication.request != latest }
            let due = (pending.filter { $0.time <= time } + settled).sorted { $0.time < $1.time }
            pending.removeAll { $0.time <= time }
            for (time, publication) in due { apply(publication, at: time) }
        }

        submit(at: clock)
        while typed < target.count {
            if interval != nil {
                if readSubmits, clock >= nextRead {
                    readSubmits = false
                    if mode == .continuous || visible.isEmpty { submit(at: nextRead) }
                }
                if clock < nextKeystroke {
                    deliver(until: clock)
                    guard let unit = await engine.runUnit() else {
                        clock = readSubmits ? min(nextKeystroke, nextRead) : nextKeystroke
                        continue
                    }
                    clock += unit.milliseconds
                    result.busy += unit.milliseconds
                    result.units += 1
                    pending += unit.publications.map { (clock, $0) }
                    continue
                }
                deliver(until: nextKeystroke)
            } else {
                while let unit = await engine.runUnit() {
                    clock += unit.milliseconds
                    result.busy += unit.milliseconds
                    result.units += 1
                    for publication in unit.publications { apply(publication, at: clock) }
                }
                nextKeystroke = clock
            }

            if visibleFresh {
                visibleFresh = false
                if let best = visible.first { result.wordsSeen.append(Metrics.units(best).count) }
            }
            let remaining = String(target[typed...])
            var accepted: String?
            if let best = visible.first {
                let chunk = WordSplitter.nextChunk(of: best, includeTrailingSpace: false, includeTrailingPunctuation: true)
                accepted = remaining.hasPrefix(best) ? best : !chunk.isEmpty && remaining.hasPrefix(chunk) ? chunk : nil
            }
            result.keystrokes += 1
            if let accepted {
                let shown = result.words.count - 1
                typed += accepted.count
                result.acceptedWords[shown] += Metrics.units(accepted).count
                if accepted == visible.first { result.acceptedInFull[shown] = true }
                if !visibleUsed {
                    result.used += 1
                    visibleUsed = true
                }
                visible = advance(visible, by: accepted)
            } else {
                typed += 1
                visible = advance(visible, by: String(target[typed - 1]))
            }
            let keystrokeTime = nextKeystroke
            nextKeystroke += interval ?? 0
            guard typed < target.count else { break }
            if visible.isEmpty { openWaits.append(keystrokeTime) }
            if keystrokeTime >= nextRead { visibleDrawn = true }
            nextRead = keystrokeTime + readLag
            let atRead = readLag > 0 && accepted == nil
            switch mode {
            case .continuous:
                if atRead { readSubmits = true } else { submit(at: keystrokeTime) }
            case .economy:
                if visible.isEmpty {
                    if atRead { readSubmits = true } else { submit(at: keystrokeTime) }
                }
            case .oneshot:
                if visible.isEmpty {
                    if inFlight == nil { submit(at: keystrokeTime) } else { followUp = true }
                }
            }
        }
        let end = nextKeystroke - (interval ?? 0)
        for opened in openWaits {
            result.waits.append(end - opened)
            result.censored.append(true)
        }
        result.elapsed = end
        while await engine.runUnit() != nil {}
        return result
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
