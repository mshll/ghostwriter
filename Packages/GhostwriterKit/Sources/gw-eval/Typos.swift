import Foundation
import Inference
import Proofing
import Synchronization

struct InjectedTypo: Codable {
    var typed: String
    var truth: String
}

struct TypoRow: Decodable {
    var id: String
    var lang: String
    var kind: String
    var operation: String?
    var app: String?
    var field: String?
    var before: String?
    var typed: String?
    var text: String?
    var truth: String
    var typos: [InjectedTypo]?
}

func loadTypoRows(from url: URL, kinds: Set<String>, limit: Int?) throws -> [TypoRow] {
    let decoder = JSONDecoder()
    let rows = try String(contentsOf: url, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .filter { !$0.allSatisfy(\.isWhitespace) }
        .map { try decoder.decode(TypoRow.self, from: Data($0.utf8)) }
        .filter { kinds.contains($0.kind) }
    return limit.map { Array(rows.prefix($0)) } ?? rows
}

struct TypoResult: Encodable {
    var id: String
    var lang: String
    var kind: String
    var operation: String?
    var typed: String
    var truth: String
    var flagged = false
    var guesses: [String] = []
    var scores: [String: Double] = [:]
    var margin: Double?
    var spellMilliseconds: Double
    var coldMilliseconds: Double?
    var warmMilliseconds: Double?
}

struct UnscoredContinuation: Error {}
struct MissingScore: Error {}

struct TypoTally: Encodable {
    var typoRows = 0
    var cleanRows = 0
    var offered = 0
    var offeredRight = 0
    var typosFixed = 0
    var cleanFlagged = 0
    var autoFixed = 0
    var autoFixedRight = 0
    var typosAutoFixed = 0
    var cleanAutoFixed = 0

    init(_ items: [(TypoResult, TypoJudge.Verdict)]) {
        for (result, verdict) in items {
            let isTypo = result.kind == "typo"
            if isTypo { typoRows += 1 } else { cleanRows += 1 }
            guard let correction = verdict.correction else { continue }
            let right = correction == result.truth
            offered += 1
            if right { offeredRight += 1 }
            if isTypo, right { typosFixed += 1 }
            if !isTypo { cleanFlagged += 1 }
            guard case .autoFix = verdict else { continue }
            autoFixed += 1
            if right { autoFixedRight += 1 }
            if isTypo, right { typosAutoFixed += 1 }
            if !isTypo { cleanAutoFixed += 1 }
        }
    }

    static func ratio(_ part: Int, _ whole: Int) -> Double? { whole > 0 ? Double(part) / Double(whole) : nil }

    var offerPrecision: Double? { Self.ratio(offeredRight, offered) }
    var recall: Double? { Self.ratio(typosFixed, typoRows) }
    var falseFlags: Double? { Self.ratio(cleanFlagged, cleanRows) }
    var autoFixPrecision: Double? { Self.ratio(autoFixedRight, autoFixed) }
    var autoFixCoverage: Double? { Self.ratio(typosAutoFixed, typoRows) }
}

struct TypoConfig: Encodable {
    var name: String
    var offerMargin: Double?
    var autoFixMargin: Double?
    var all: TypoTally
    var byLanguage: [String: TypoTally]
}

struct TypoLatency: Encodable {
    var spellP50: Double
    var spellP95: Double
    var coldP50: Double
    var coldP95: Double
    var warmP50: Double
    var warmP95: Double
    var judgedRows: Int
}

struct TypoReport: Encodable {
    var model: String
    var configs: [TypoConfig]
    var latency: TypoLatency
    var rows: [TypoResult]
}

@MainActor
func evaluateTypos(_ options: Options, set: URL) async throws {
    let rows = try loadTypoRows(from: set, kinds: ["typo", "clean"], limit: options.limit)
    let harness = try await Harness.load(options)
    let engine = harness.engine
    let start = ContinuousClock.now
    var results: [TypoResult] = []
    var misspellings: [Misspelling?] = []
    for (index, row) in rows.enumerated() {
        guard let before = row.before, let typed = row.typed else { continue }
        let spellStart = ContinuousClock.now
        let misspelling = SpellCheck.lastWord(in: before, language: row.lang)
        var result = TypoResult(
            id: row.id, lang: row.lang, kind: row.kind, operation: row.operation, typed: typed, truth: row.truth,
            spellMilliseconds: milliseconds(since: spellStart)
        )
        if let misspelling, !misspelling.guesses.isEmpty {
            result.flagged = true
            result.typed = misspelling.word
            result.guesses = misspelling.guesses
            let prefix = String(before.dropLast(misspelling.distanceFromEnd + misspelling.word.count))
            let suffix = String(before.suffix(misspelling.distanceFromEnd))
            let request = harness.request(for: Row(id: row.id, app: row.app, kind: row.field, before: prefix), before: prefix)
            let prompt = request.prompt
            let partial = request.partialWord
            let scores = Mutex<[String: Double]>([:])
            let live: @Sendable (String) async throws -> Double = { candidate in
                let scored = try await engine.score(prompt: prompt, continuation: partial + candidate + suffix)
                guard scored.characters > 0 else { throw UnscoredContinuation() }
                scores.withLock { $0[candidate] = scored.logprob }
                return scored.logprob
            }
            await engine.clearCache()
            let cold = ContinuousClock.now
            let judgment = await TypoJudge().judge(misspelling, score: live)
            result.coldMilliseconds = milliseconds(since: cold)
            let warm = ContinuousClock.now
            _ = await TypoJudge().judge(misspelling, score: live)
            result.warmMilliseconds = milliseconds(since: warm)
            result.margin = judgment.margin
            result.scores = scores.withLock { $0 }
        }
        results.append(result)
        misspellings.append(result.flagged ? misspelling : nil)
        if options.verbose || (index + 1) % 250 == 0 {
            print("\(index + 1)/\(rows.count) rows, \(format(milliseconds(since: start) / 1000)) s")
        }
        if options.verbose, result.flagged {
            print("  \(row.id) \(result.typed) -> \(result.guesses.joined(separator: ", ")) truth \(row.truth) margin \(format(result.margin, 2))")
        }
    }

    func replayed(_ judge: TypoJudge?) async -> [TypoJudge.Verdict] {
        var verdicts: [TypoJudge.Verdict] = []
        for (result, misspelling) in zip(results, misspellings) {
            guard let misspelling else {
                verdicts.append(.keep)
                continue
            }
            guard let judge else {
                verdicts.append(.offer(misspelling.guesses[0]))
                continue
            }
            let scores = result.scores
            let replay: (@Sendable (String) async throws -> Double)? = result.margin == nil ? nil : { @Sendable candidate in
                guard let value = scores[candidate] else { throw MissingScore() }
                return value
            }
            verdicts.append(await judge.judge(misspelling, score: replay).verdict)
        }
        return verdicts
    }

    func config(_ name: String, offer: Double?, autoFix: Double?, _ verdicts: [TypoJudge.Verdict]) -> TypoConfig {
        let items = Array(zip(results, verdicts))
        let byLanguage = Dictionary(grouping: items) { $0.0.lang }.mapValues(TypoTally.init)
        return TypoConfig(name: name, offerMargin: offer, autoFixMargin: autoFix, all: TypoTally(items), byLanguage: byLanguage)
    }

    let defaults = TypoJudge()
    var configs = [config("spell checker", offer: nil, autoFix: nil, await replayed(nil))]
    configs.append(config(
        "judge default", offer: defaults.offerMargin, autoFix: defaults.autoFixMargin, await replayed(defaults)
    ))
    let offerMargins: [Double] = [0, 0.5, 1, 2, 3, 4]
    for offer in offerMargins {
        let judge = TypoJudge(offerMargin: offer, autoFixMargin: .infinity)
        configs.append(config("offer \(format(offer))", offer: offer, autoFix: nil, await replayed(judge)))
    }
    let autoFixMargins: [Double] = Array(3...10).map(Double.init)
    for autoFix in autoFixMargins {
        let judge = TypoJudge(offerMargin: 0, autoFixMargin: autoFix, autoFixGap: 0)
        configs.append(config("auto-fix \(format(autoFix, 0))", offer: 0, autoFix: autoFix, await replayed(judge)))
    }
    for gap in [3.0, 4, 5, 6] {
        let judge = TypoJudge(offerMargin: 0, autoFixMargin: defaults.autoFixMargin, autoFixGap: gap)
        configs.append(config(
            "auto-fix \(format(defaults.autoFixMargin, 0)) gap \(format(gap, 0))", offer: 0, autoFix: defaults.autoFixMargin,
            await replayed(judge)
        ))
    }

    let judged = results.filter { $0.coldMilliseconds != nil }
    let latency = TypoLatency(
        spellP50: Metrics.percentile(results.map(\.spellMilliseconds), 0.5),
        spellP95: Metrics.percentile(results.map(\.spellMilliseconds), 0.95),
        coldP50: Metrics.percentile(judged.compactMap(\.coldMilliseconds), 0.5),
        coldP95: Metrics.percentile(judged.compactMap(\.coldMilliseconds), 0.95),
        warmP50: Metrics.percentile(judged.compactMap(\.warmMilliseconds), 0.5),
        warmP95: Metrics.percentile(judged.compactMap(\.warmMilliseconds), 0.95),
        judgedRows: judged.count
    )
    printTypoReport(results: results, configs: configs, latency: latency)

    if let json = options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(TypoReport(model: options.model.lastPathComponent, configs: configs, latency: latency, rows: results)).write(to: json)
        print("wrote \(json.path)")
    }
}

func printTypoReport(results: [TypoResult], configs: [TypoConfig], latency: TypoLatency) {
    func share(_ members: [TypoResult], _ test: (TypoResult) -> Bool) -> String {
        percent(TypoTally.ratio(members.filter(test).count, members.count)).leftPadded(7)
    }
    let typos = results.filter { $0.kind == "typo" }
    let clean = results.filter { $0.kind == "clean" }
    let unscored = results.filter { $0.flagged && $0.margin == nil }.count
    print("\n\(typos.count) typo rows, \(clean.count) clean rows, \(unscored) flagged rows the model could not score")

    print("\nspell checker on typo rows")
    printGroups("lang", typos, key: \.lang, columns: "  rows flagged in-guess in-top3   first", line: { members in
        String(members.count).leftPadded(5)
            + share(members, \.flagged)
            + share(members) { $0.guesses.contains($0.truth) }
            + share(members) { $0.guesses.prefix(TypoJudge.scoredGuesses).contains($0.truth) }
            + share(members) { $0.guesses.first == $0.truth }
    })
    printGroups("error", typos, key: { $0.operation ?? "-" }, columns: "  rows flagged in-guess in-top3   first", line: { members in
        String(members.count).leftPadded(5)
            + share(members, \.flagged)
            + share(members) { $0.guesses.contains($0.truth) }
            + share(members) { $0.guesses.prefix(TypoJudge.scoredGuesses).contains($0.truth) }
            + share(members) { $0.guesses.first == $0.truth }
    })

    func row(_ name: String, _ tally: TypoTally) -> String {
        name.padding(toLength: 16, withPad: " ", startingAt: 0)
            + percent(tally.offerPrecision).leftPadded(9) + percent(tally.recall).leftPadded(9) + percent(tally.falseFlags).leftPadded(9)
            + percent(tally.autoFixPrecision).leftPadded(9) + percent(tally.autoFixCoverage).leftPadded(9)
            + String(tally.cleanAutoFixed).leftPadded(7)
    }
    let header = "config".padding(toLength: 16, withPad: " ", startingAt: 0) + "  offer-P   recall  f-flags   auto-P  auto-cov  clean-auto"
    print("\nall languages (offer-P = offers that are the truth; recall and auto-cov over typo rows; f-flags over clean rows)")
    print(header)
    for config in configs { print(row(config.name, config.all)) }

    let languages = Set(results.map(\.lang)).sorted()
    for config in configs where config.name == "spell checker" || config.name == "judge default" {
        print("\n\(config.name) by language")
        print(header.replacingOccurrences(of: "config", with: "lang  "))
        for language in languages {
            if let tally = config.byLanguage[language] { print(row(language, tally)) }
        }
    }

    print("""

        latency (\(latency.judgedRows) judged rows)
        spell check p50/p95  \(format(latency.spellP50, 2)) / \(format(latency.spellP95, 2)) ms
        judge cold p50/p95   \(format(latency.coldP50, 0)) / \(format(latency.coldP95, 0)) ms   (cache cleared)
        judge warm p50/p95   \(format(latency.warmP50, 0)) / \(format(latency.warmP95, 0)) ms   (prompt cached)
        """)
}
