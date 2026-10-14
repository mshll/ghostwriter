import Actions
import Foundation

struct ProofreadResult: Encodable {
    var id: String
    var lang: String
    var text: String
    var truth: String
    var corrected: String?
    var failure: String?
    var milliseconds: Double
    var injected = 0
    var fixed = 0
    var otherWords = 0
    var overEdits = 0
    var exact = false
    var unchanged = false
    var rewritesTooMuch = false
}

struct ProofreadTally: Encodable {
    var rows: Int
    var failures: Int
    var exact: Int
    var unchanged: Int
    var injected: Int
    var fixed: Int
    var otherWords: Int
    var overEdits: Int
    var overEditedRows: Int
    var rewritesTooMuch: Int

    init(_ results: [ProofreadResult]) {
        let answered = results.filter { $0.failure == nil }
        rows = results.count
        failures = rows - answered.count
        exact = answered.filter(\.exact).count
        unchanged = answered.filter(\.unchanged).count
        injected = answered.map(\.injected).reduce(0, +)
        fixed = answered.map(\.fixed).reduce(0, +)
        otherWords = answered.map(\.otherWords).reduce(0, +)
        overEdits = answered.map(\.overEdits).reduce(0, +)
        overEditedRows = answered.filter { $0.overEdits > 0 }.count
        rewritesTooMuch = answered.filter(\.rewritesTooMuch).count
    }

    var line: String {
        let answered = rows - failures
        return [
            String(rows).leftPadded(5), String(failures).leftPadded(6),
            percent(TypoTally.ratio(exact, answered)).leftPadded(7),
            percent(TypoTally.ratio(fixed, injected)).leftPadded(7),
            percent(TypoTally.ratio(overEdits, otherWords)).leftPadded(9),
            percent(TypoTally.ratio(overEditedRows, answered)).leftPadded(9),
            percent(TypoTally.ratio(rewritesTooMuch, answered)).leftPadded(8),
            percent(TypoTally.ratio(unchanged, answered)).leftPadded(9),
        ].joined()
    }
}

struct ProofreadReport: Encodable {
    var all: ProofreadTally
    var byLanguage: [String: ProofreadTally]
    var failures: [String: Int]
    var coldMilliseconds: Double?
    var p50: Double
    var p95: Double
    var rows: [ProofreadResult]
}

func evaluateProofread(_ options: Options, set: URL) async throws {
    if let reason = WritingAssistant.unavailableReason { throw UsageError("Apple's on-device model is unavailable: \(reason)") }
    let rows = try loadTypoRows(from: set, kinds: ["sentence"], limit: options.limit)
    let assistant = WritingAssistant()
    var results: [ProofreadResult] = []
    for row in rows {
        guard let text = row.text else { continue }
        let start = ContinuousClock.now
        var output = ""
        var failure: String?
        do {
            for try await snapshot in assistant.run(.fixGrammar, on: text) { output = snapshot }
        } catch {
            failure = String(describing: error)
            FileHandle.standardError.write(Data("\(row.id): \(error.localizedDescription)\n".utf8))
        }
        var result = ProofreadResult(
            id: row.id, lang: row.lang, text: text, truth: row.truth, failure: failure, milliseconds: milliseconds(since: start)
        )
        if failure == nil { measure(Proofread(original: text, modelOutput: output), into: &result) }
        results.append(result)
        if options.verbose {
            print("\(row.id) \(format(result.milliseconds, 0)) ms fixed \(result.fixed)/\(result.injected) over \(result.overEdits): \(clip(result.corrected ?? failure ?? "", 120))")
        }
    }

    let answered = results.dropFirst().filter { $0.failure == nil }.map(\.milliseconds)
    let failures = Dictionary(grouping: results.compactMap(\.failure)) { $0 }.mapValues(\.count)
    let report = ProofreadReport(
        all: ProofreadTally(results),
        byLanguage: Dictionary(grouping: results, by: \.lang).mapValues(ProofreadTally.init),
        failures: failures,
        coldMilliseconds: results.first?.milliseconds,
        p50: Metrics.percentile(answered, 0.5),
        p95: Metrics.percentile(answered, 0.95),
        rows: results
    )
    print("\nlang      rows  fails  exact  typo-fix over-edit edit-rows rewrite unchanged")
    for (language, tally) in report.byLanguage.sorted(by: { $0.key < $1.key }) {
        print(language.padding(toLength: 8, withPad: " ", startingAt: 0), tally.line)
    }
    print("all".padding(toLength: 8, withPad: " ", startingAt: 0), report.all.line)
    print("(typo-fix over injected typos, over-edit over the other words, edit-rows: rows with any over-edit)")
    for (reason, count) in failures.sorted(by: { $0.value > $1.value }) { print("failure \(count)x \(reason)") }
    print("latency first call \(format(report.coldMilliseconds, 0)) ms, then p50/p95 \(format(report.p50, 0)) / \(format(report.p95, 0)) ms")

    if let json = options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: json)
        print("wrote \(json.path)")
    }
}

private func measure(_ proofread: Proofread, into result: inout ProofreadResult) {
    let original = words(result.text)
    let truth = words(result.truth)
    let corrected = words(proofread.corrected)
    result.corrected = proofread.corrected
    result.exact = proofread.corrected == result.truth
    result.unchanged = proofread.isUnchanged
    result.rewritesTooMuch = proofread.rewritesTooMuch
    guard original.count == truth.count else { return }
    let injected = Set(original.indices.filter { original[$0] != truth[$0] })
    let truthLost = removedOffsets(corrected.difference(from: truth))
    let originalLost = removedOffsets(corrected.difference(from: original))
    result.injected = injected.count
    result.fixed = injected.subtracting(truthLost).count
    result.otherWords = original.count - injected.count
    result.overEdits = originalLost.subtracting(injected).count
}

private func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
}

private func removedOffsets(_ difference: CollectionDifference<String>) -> Set<Int> {
    Set(difference.removals.map { change in
        switch change {
        case .remove(let offset, _, _), .insert(let offset, _, _): offset
        }
    })
}
