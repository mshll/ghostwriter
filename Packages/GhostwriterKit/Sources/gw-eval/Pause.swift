import Foundation
import Inference

struct PauseResult: Encodable {
    var id: String
    var lang: String
    var typed: String
    var completion: String
    var firstShown: String
    var firstShownMilliseconds: Double?
    var finalBest: String
    var replacedAfterTyping = 0
    var replacedMilliseconds: [Double] = []
    var replaced = 0
    var shown = 0
    var truth: String
}

func simulatePause(_ options: Options, set: URL) async throws {
    let rows = try loadRows(from: set, limit: options.limit).filter { $0.truth != nil }
    let harness = try await Harness.load(options, stepping: .manual)
    let interval = 1000 / (options.typingSpeed ?? 6.67)
    var results: [PauseResult] = []
    let start = ContinuousClock.now
    for row in rows {
        let result = try await pauseRow(row, harness: harness, interval: interval)
        results.append(result)
        if options.verbose {
            print(result.id, "shown \(clip(result.completion, 30)) | first \(clip(result.firstShown, 30)) | final \(clip(result.finalBest, 30)) | replaced \(result.replaced)")
        }
    }
    print("pause test: \(results.count) rows in \(format(milliseconds(since: start) / 1000)) s, \(options.pauseTyped) characters typed at \(format(1000 / interval)) per second, read \(format(options.pause, 0)) ms after the last")
    func line(_ members: [PauseResult]) -> String {
        func scores(_ text: KeyPath<PauseResult, String>) -> (first: Double, matched: Double) {
            let matched = members.map { Metrics.commonPrefix(Metrics.units($0[keyPath: text]), Metrics.units($0.truth)) }
            let n = Double(max(members.count, 1))
            return (Double(matched.filter { $0 > 0 }.count) / n, Double(matched.reduce(0, +)) / n)
        }
        let shown = scores(\.completion), first = scores(\.firstShown), final = scores(\.finalBest)
        let n = Double(max(members.count, 1))
        return [
            String(members.count).leftPadded(5),
            percent(shown.first).leftPadded(8), format(shown.matched, 2).leftPadded(8),
            percent(first.first).leftPadded(8), format(first.matched, 2).leftPadded(8),
            percent(final.first).leftPadded(8), format(final.matched, 2).leftPadded(8),
            format(Double(members.map(\.replacedAfterTyping).reduce(0, +)) / n, 2).leftPadded(9),
            format(Double(members.map(\.replaced).reduce(0, +)) / n, 2).leftPadded(9),
        ].joined(separator: " ")
    }
    let columns = " rows  shown1st  matched  first1st  matched  final1st  matched  repl/row  repl-all"
    printGroups("lang", results, key: \.lang, columns: columns, line: line)
    if let json = options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(results).write(to: json)
        print("wrote \(json.path)")
    }
}

private func pauseRow(_ row: Row, harness: Harness, interval: Double) async throws -> PauseResult {
    let engine = harness.engine
    let options = harness.options
    let characters = Array(row.before)
    let typedCount = min(options.pauseTyped, characters.count)
    let prefix = String(characters.dropLast(typedCount))
    let rawTail = characters.suffix(typedCount).map { String($0) }
    let tail = rawTail.map(folded)
    var result = PauseResult(
        id: row.id, lang: language(of: row), typed: tail.joined(), completion: "", firstShown: "", finalBest: "", truth: row.truth ?? ""
    )
    await engine.clearCache()

    var typed = 0
    var visible: [String] = []
    var visibleDrawn = false
    var nextRead = 0.0
    var requests: [Int: Int] = [:]
    var pending: [(time: Double, publication: Publication)] = []
    var clock = 0.0
    let lastKey = interval * Double(typedCount - 1)
    let readAt = lastKey + options.pause

    func apply(_ publication: Publication, at time: Double) {
        guard let issuedTyped = requests[publication.request] else { return }
        let update = publication.update
        guard update.isFinal || !options.finalOnly else { return }
        let candidates = advance(update.candidates.map { folded($0.text) }, by: tail[issuedTyped..<typed].joined())
        if update.isFinal, issuedTyped == typedCount { result.finalBest = candidates.first ?? "" }
        guard !candidates.isEmpty else { return }
        let drawn = time >= nextRead || (visibleDrawn && !visible.isEmpty)
        let merged = ShownSuggestion.merge(shown: visible, drawn: drawn, update: candidates)
        let replaces = drawn && visible.first.map { !merged[0].hasPrefix($0) } ?? false
        if visible.isEmpty || replaces {
            visibleDrawn = drawn
            result.shown += 1
            if replaces {
                result.replaced += 1
                if typed == typedCount {
                    result.replacedAfterTyping += 1
                    result.replacedMilliseconds.append(time - lastKey)
                }
            }
            if typed == typedCount, result.firstShownMilliseconds == nil {
                result.firstShown = merged[0]
                result.firstShownMilliseconds = max(time, nextRead) - lastKey
            }
        } else if !drawn, typed == typedCount {
            result.firstShown = merged[0]
        }
        visible = merged
    }

    func deliver(until time: Double) {
        let due = pending.filter { $0.time <= time }
        pending.removeAll { $0.time <= time }
        for (at, publication) in due { apply(publication, at: at) }
    }

    func runUntil(_ time: Double) async {
        while clock < time {
            deliver(until: clock)
            guard let unit = await engine.runUnit() else {
                clock = time
                break
            }
            clock += unit.milliseconds
            pending += unit.publications.map { (clock, $0) }
        }
        deliver(until: time)
    }

    for index in 0..<typedCount {
        await runUntil(interval * Double(index))
        typed += 1
        visible = advance(visible, by: tail[typed - 1])
        if result.firstShownMilliseconds == nil, typed == typedCount, let shown = visible.first {
            result.firstShown = shown
            result.firstShownMilliseconds = 0
        }
        let read = interval * Double(index) + options.readLag
        nextRead = read
        await runUntil(read)
        visibleDrawn = true
        let subscription = engine.suggestions(for: try harness.request(for: row, before: prefix + rawTail[..<typed].joined()))
        requests[subscription.id] = typed
    }
    await runUntil(readAt)
    result.completion = visible.first ?? ""
    while await engine.runUnit() != nil {}
    return result
}
