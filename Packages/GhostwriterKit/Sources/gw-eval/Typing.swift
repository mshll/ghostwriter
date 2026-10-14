import Foundation
import Inference
import Input
import Prompting

func language(of row: Row) -> String {
    let code = row.lang ?? LanguageDetector.dominantLanguage(of: row.before) ?? "?"
    return String(code.prefix { $0 != "-" })
}

func printGroups<Value>(_ title: String, _ items: [Value], key: (Value) -> String, columns: String, line: ([Value]) -> String) {
    print("\n\(title.padding(toLength: 8, withPad: " ", startingAt: 0)) \(columns)")
    let groups = Dictionary(grouping: items, by: key).sorted { $0.value.count > $1.value.count }
    for (name, members) in groups {
        print(name.padding(toLength: 8, withPad: " ", startingAt: 0), line(members))
    }
    print("all".padding(toLength: 8, withPad: " ", startingAt: 0), line(items))
}

struct ScoreResult: Encodable {
    var id: String
    var lang: String
    var kind: String?
    var source: String?
    var bits: Double
    var characters: Int
    var tokens: Int
}

func score(_ options: Options, set: URL) async throws {
    let rows = try loadRows(from: set, limit: options.limit).filter { $0.truth != nil }
    let harness = try await Harness.load(options)
    var results: [ScoreResult] = []
    let start = ContinuousClock.now
    for row in rows {
        let request = harness.request(for: row, before: row.before)
        let score = try await harness.engine.score(prompt: request.prompt, continuation: request.partialWord + (row.truth ?? ""))
        guard score.characters > 0 else { continue }
        results.append(ScoreResult(
            id: row.id, lang: language(of: row), kind: row.kind, source: row.source,
            bits: -score.logprob / log(2), characters: score.characters, tokens: score.tokens
        ))
    }
    func line(_ members: [ScoreResult]) -> String {
        let bits = members.map(\.bits).reduce(0, +)
        let characters = members.map(\.characters).reduce(0, +)
        let tokens = members.map(\.tokens).reduce(0, +)
        return "\(String(members.count).leftPadded(5)) \(format(bits / Double(max(characters, 1)), 3).leftPadded(7)) \(format(Double(characters) / Double(max(tokens, 1)), 2).leftPadded(8))"
    }
    print("scored \(results.count) rows in \(format(milliseconds(since: start) / 1000)) s")
    printGroups("lang", results, key: \.lang, columns: " rows     bpc  chars/tok", line: line)
    printGroups("kind", results, key: { $0.kind ?? "-" }, columns: " rows     bpc  chars/tok", line: line)
    if let json = options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: json)
        print("wrote \(json.path)")
    }
}

struct TypingResult: Encodable {
    var id: String
    var lang: String
    var kind: String?
    var source: String?
    var characters: Int
    var keystrokes: Int
    var requests: Int
    var shown: Int
    var used: Int
    var milliseconds: [Double]
    var late: Int?
    var scores: [Double] = []
    var agreement: [Double] = []
    var accepted: [Bool] = []
    var words: [Int] = []
    var acceptedWords: [Int] = []
    var acceptedInFull: [Bool] = []
}

/// Each row starts with the cache holding the prompt from one keystroke earlier, as when typing without pause.
func simulateTyping(_ options: Options, set: URL) async throws {
    let rows = try loadRows(from: set, limit: options.limit).filter { $0.truth != nil }
    let suggester: any Suggester = switch options.backend {
    case .llama: try await LlamaSuggester(harness: Harness.load(options))
    case .foundation: try await FoundationSuggester.load(maxWords: options.maxWords)
    }
    let interval = options.typingSpeed.map { 1000 / $0 }
    var results: [TypingResult] = []
    let start = ContinuousClock.now
    for row in rows {
        let target = Array(folded(row.truth ?? ""))
        await suggester.reset()
        if interval != nil { await suggester.prewarm(for: row, before: String(row.before.dropLast())) }
        var result = TypingResult(
            id: row.id, lang: language(of: row), kind: row.kind, source: row.source,
            characters: target.count, keystrokes: 0, requests: 0, shown: 0, used: 0, milliseconds: [], late: interval.map { _ in 0 }
        )
        var typed = 0
        var suggestion: [String] = []
        var suggestionUsed = false
        var engineFree = 0.0
        while typed < target.count {
            if suggestion.isEmpty {
                let issued = typed
                let requested = ContinuousClock.now
                let candidates = try await suggester.suggest(for: row, before: row.before + String(target[..<typed]))
                let latency = milliseconds(since: requested)
                result.requests += 1
                result.milliseconds.append(latency)
                if options.verbose, typed == 0 { print(row.id, "->", candidates.first?.text.debugDescription ?? "(none)", "| truth:", (row.truth ?? "").debugDescription) }
                if let interval {
                    let ready = max(Double(result.keystrokes) * interval, engineFree) + latency
                    engineFree = ready
                    if ready > Double(result.keystrokes + 1) * interval { result.late? += 1 }
                    while typed < target.count, Double(result.keystrokes + 1) * interval < ready {
                        result.keystrokes += 1
                        typed += 1
                    }
                    if typed == target.count { break }
                }
                suggestion = advance(candidates.map { folded($0.text) }.filter { !$0.isEmpty }, by: String(target[issued..<typed]))
                suggestionUsed = false
                if !suggestion.isEmpty {
                    result.shown += 1
                    result.scores.append(candidates.first { !$0.text.isEmpty }?.score ?? 0)
                    result.agreement.append(firstWordAgreement(candidates))
                    result.accepted.append(false)
                    result.words.append(Metrics.units(suggestion[0]).count)
                    result.acceptedWords.append(0)
                    result.acceptedInFull.append(false)
                } else if typed > issued {
                    continue
                }
            }
            let remaining = String(target[typed...])
            var accepted: String?
            if let best = suggestion.first {
                let chunk = WordSplitter.nextChunk(of: best, includeTrailingSpace: false, includeTrailingPunctuation: true)
                accepted = remaining.hasPrefix(best) ? best : !chunk.isEmpty && remaining.hasPrefix(chunk) ? chunk : nil
            }
            if let accepted {
                let shown = result.accepted.count - 1
                result.keystrokes += 1
                typed += accepted.count
                result.acceptedWords[shown] += Metrics.units(accepted).count
                if accepted == suggestion.first { result.acceptedInFull[shown] = true }
                suggestion = advance(suggestion, by: accepted)
                if !suggestionUsed {
                    result.used += 1
                    result.accepted[shown] = true
                }
                suggestionUsed = true
            } else {
                result.keystrokes += 1
                typed += 1
                suggestion = advance(suggestion, by: String(target[typed - 1]))
            }
        }
        results.append(result)
        if options.verbose {
            print(row.id, result.lang, "saved \(result.characters - result.keystrokes)/\(result.characters)", "requests \(result.requests)", "used \(result.used)/\(result.shown)" + (result.late.map { " late \($0)" } ?? ""))
        }
    }
    func line(_ members: [TypingResult]) -> String {
        let characters = members.map(\.characters).reduce(0, +)
        let keystrokes = members.map(\.keystrokes).reduce(0, +)
        let shown = members.map(\.shown).reduce(0, +)
        let used = members.map(\.used).reduce(0, +)
        let latencies = members.flatMap(\.milliseconds)
        let saved = Double(characters - keystrokes) / Double(max(characters, 1))
        let perShown = Double(max(shown, 1))
        let words = members.flatMap(\.words)
        let phrases = [
            format(Double(words.reduce(0, +)) / perShown, 2).leftPadded(6),
            percent(Double(words.filter { $0 == 1 }.count) / perShown).leftPadded(7),
            format(Double(members.flatMap(\.acceptedWords).reduce(0, +)) / perShown, 2).leftPadded(8),
            percent(Double(members.flatMap(\.acceptedInFull).filter { $0 }.count) / perShown).leftPadded(7),
        ].joined(separator: " ")
        let lateShare = Double(members.compactMap(\.late).reduce(0, +)) / Double(max(members.map(\.requests).reduce(0, +), 1))
        let late = interval == nil ? "" : " " + percent(lateShare).leftPadded(7)
        return "\(String(members.count).leftPadded(5)) \(percent(saved).leftPadded(7)) \(percent(Double(used) / Double(max(shown, 1))).leftPadded(7)) \(format(Metrics.percentile(latencies, 0.5), 0).leftPadded(6)) \(format(Metrics.percentile(latencies, 0.95), 0).leftPadded(6)) \(phrases)\(late)"
    }
    let columns = " rows   saved  useful    p50    p95  words  single accepted    full" + (interval == nil ? "" : "    late")
    print("simulated \(results.count) rows in \(format(milliseconds(since: start) / 1000)) s" + (options.typingSpeed.map { " at \(format($0)) characters per second" } ?? ""))
    printGroups("lang", results, key: \.lang, columns: columns, line: line)
    printGroups("kind", results, key: { $0.kind ?? "-" }, columns: columns, line: line)
    if let json = options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: json)
        print("wrote \(json.path)")
    }
}

protocol Suggester {
    func reset() async
    func prewarm(for row: Row, before: String) async
    func suggest(for row: Row, before: String) async throws -> [Candidate]
}

struct LlamaSuggester: Suggester {
    var harness: Harness

    func reset() async {
        await harness.engine.clearCache()
    }

    func prewarm(for row: Row, before: String) async {
        await harness.engine.prewarm(prompt: harness.request(for: row, before: before).prompt)
    }

    func suggest(for row: Row, before: String) async throws -> [Candidate] {
        try await harness.engine.complete(harness.request(for: row, before: before))
    }
}

private func firstWordAgreement(_ candidates: [Candidate]) -> Double {
    let options = candidates.filter { !$0.text.isEmpty }
    guard let best = options.first else { return 0 }
    func firstWord(_ text: String) -> String {
        WordSplitter.nextChunk(of: text, includeTrailingSpace: false, includeTrailingPunctuation: false)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }
    let head = firstWord(best.text)
    let weights = options.map { exp($0.score - best.score) }
    let agreeing = zip(options, weights).filter { firstWord($0.0.text) == head }.map(\.1).reduce(0, +)
    return agreeing / weights.reduce(0, +)
}

func folded(_ text: String) -> String {
    String(text.map { character -> Character in
        switch character {
        case "\u{2018}", "\u{2019}": "'"
        case "\u{201C}", "\u{201D}": "\""
        case "\u{00A0}": " "
        default: character
        }
    })
}

func advance(_ candidates: [String], by typed: String) -> [String] {
    candidates.compactMap { candidate in
        candidate.hasPrefix(typed) && candidate.count > typed.count ? String(candidate.dropFirst(typed.count)) : nil
    }
}
