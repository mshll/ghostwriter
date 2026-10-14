import Foundation
import Prompting

struct WordUnit: Equatable {
    var text: String
    var end: Int
}

enum Metrics {
    static func units(_ text: String) -> [WordUnit] {
        var units: [WordUnit] = []
        var current = ""
        var offset = 0
        func flush() {
            if !current.isEmpty { units.append(WordUnit(text: current.lowercased(), end: offset)) }
            current = ""
        }
        for character in text {
            if isCJK(character) {
                flush()
                offset += 1
                units.append(WordUnit(text: String(character), end: offset))
                continue
            }
            if character.isLetter || character.isNumber || (!current.isEmpty && "'’-".contains(character)) {
                current.append(character)
            } else {
                flush()
            }
            offset += 1
        }
        flush()
        return units.map { unit in
            var unit = unit
            while let last = unit.text.last, "'’-".contains(last) { unit.text.removeLast() }
            return unit
        }
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(value) || (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value)
            || (0xFF66...0xFF9F).contains(value)
    }

    static func commonPrefix(_ a: [WordUnit], _ b: [WordUnit]) -> Int {
        zip(a, b).prefix { $0.text == $1.text }.count
    }

    static func isLonePunctuation(_ text: String) -> Bool {
        !text.isEmpty && !text.contains { $0.isLetter || $0.isNumber }
    }

    static func breaksLine(completion: String, after: String) -> Bool {
        let trimmed = completion.trimmingCharacters(in: .whitespaces)
        let next = after.drop { $0 == " " }.first
        if let last = trimmed.last, ".!?。！？".contains(last), let next, next.isLetter || next.isNumber {
            return true
        }
        let completionUnits = units(completion).map(\.text)
        let afterUnits = units(after).map(\.text)
        let longest = min(3, completionUnits.count, afterUnits.count)
        guard longest > 0 else { return false }
        return (1...longest).contains { Array(completionUnits.suffix($0)) == Array(afterUnits.prefix($0)) }
    }

    static func echoesLabel(_ completion: String) -> Bool {
        BuiltPrompt.stopStrings.contains { !$0.isEmpty && completion.contains($0) }
    }

    static func copiesVerbatim(_ completion: String, from before: String) -> Bool {
        let words = units(completion).map(\.text)
        let source = units(before).map(\.text)
        if words.count >= 8, source.count >= 8 {
            let grams = Set((0...(source.count - 8)).map { source[$0..<($0 + 8)].joined(separator: " ") })
            if (0...(words.count - 8)).contains(where: { grams.contains(words[$0..<($0 + 8)].joined(separator: " ")) }) { return true }
        }
        let characters = Array(completion)
        guard characters.count >= 40 else { return false }
        return (0...(characters.count - 40)).contains { before.contains(String(characters[$0..<($0 + 40)])) }
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
        return sorted[index]
    }
}

struct RowResult: Codable {
    var id: String
    var kind: String?
    var midLine: Bool
    var completion: String
    var alternatives: [String]
    var truth: String?
    var reference: String?
    var warmCompletion: String?
    var empty: Bool
    var bad: Bool
    var labelEcho: Bool
    var verbatimCopy: Bool
    var exactNextWord: Bool?
    var acceptedWords: Int?
    var truthWords: Int?
    var completionWords: Int
    var charsSaved: Int?
    var referenceNextWord: Bool?
    var coldMilliseconds: Double
    var warmMilliseconds: Double?
    var promptTokens: Int
    var reusedTokensWarm: Int?
    var prefillMilliseconds: Double
    var steps: Int
    var searchMilliseconds: Double
    var rerankMilliseconds: Double

    static func score(
        id: String, kind: String?, before: String, after: String, completion: String, alternatives: [String], truth: String?,
        reference: String?
    ) -> RowResult {
        let completionUnits = Metrics.units(completion)
        let midLine = !after.isEmpty
        var result = RowResult(
            id: id, kind: kind, midLine: midLine, completion: completion, alternatives: alternatives, truth: truth,
            reference: reference, empty: completion.isEmpty,
            bad: Metrics.isLonePunctuation(completion) || (midLine && !completion.isEmpty && Metrics.breaksLine(completion: completion, after: after)),
            labelEcho: Metrics.echoesLabel(completion), verbatimCopy: Metrics.copiesVerbatim(completion, from: before),
            completionWords: completionUnits.count, coldMilliseconds: 0, promptTokens: 0, prefillMilliseconds: 0, steps: 0,
            searchMilliseconds: 0, rerankMilliseconds: 0
        )
        if let truth {
            let truthUnits = Metrics.units(truth)
            let accepted = Metrics.commonPrefix(completionUnits, truthUnits)
            result.exactNextWord = accepted > 0
            result.acceptedWords = accepted
            result.truthWords = truthUnits.count
            result.charsSaved = accepted > 0 ? completionUnits[accepted - 1].end : 0
        }
        if let reference {
            result.referenceNextWord = Metrics.commonPrefix(completionUnits, Metrics.units(reference)) > 0
        }
        return result
    }
}

struct Summary: Codable {
    var rows: Int
    var variant: String
    var beams: Int
    var maxWords: Int
    var exactNextWord: Double?
    var acceptedRecall: Double?
    var acceptedPrecision: Double?
    var charsSaved: Double?
    var badRate: Double
    var badRateMidLine: Double?
    var labelEchoRate: Double
    var verbatimCopyRate: Double
    var emptyRate: Double
    var emptyRateMidLine: Double?
    var exactNextWordMidLine: Double?
    var referenceNextWord: Double?
    var meanCompletionWords: Double
    var coldP50: Double
    var coldP95: Double
    var warmP50: Double?
    var warmP95: Double?
    var prefillTokensPerSecond: Double
    var stepMilliseconds: Double
    var meanSteps: Double

    init(results: [RowResult], options: Options) {
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        func rate(_ flags: [Bool]) -> Double? { mean(flags.map { $0 ? 1 : 0 }) }
        let truthRows = results.filter { $0.truth != nil }
        let midLine = results.filter(\.midLine)
        rows = results.count
        variant = options.variant
        beams = options.beams
        maxWords = options.maxWords
        exactNextWord = rate(truthRows.compactMap(\.exactNextWord))
        exactNextWordMidLine = rate(truthRows.filter(\.midLine).compactMap(\.exactNextWord))
        acceptedRecall = mean(truthRows.compactMap { row in
            guard let accepted = row.acceptedWords, let truth = row.truthWords, truth > 0 else { return nil }
            return Double(accepted) / Double(min(truth, options.maxWords))
        })
        acceptedPrecision = mean(truthRows.compactMap { row in
            guard let accepted = row.acceptedWords, row.completionWords > 0 else { return nil }
            return Double(accepted) / Double(row.completionWords)
        })
        charsSaved = mean(truthRows.compactMap { $0.charsSaved.map(Double.init) })
        badRate = rate(results.map(\.bad)) ?? 0
        badRateMidLine = rate(midLine.map(\.bad))
        labelEchoRate = rate(results.map(\.labelEcho)) ?? 0
        verbatimCopyRate = rate(results.map(\.verbatimCopy)) ?? 0
        emptyRate = rate(results.map(\.empty)) ?? 0
        emptyRateMidLine = rate(midLine.map(\.empty))
        referenceNextWord = rate(results.compactMap(\.referenceNextWord))
        meanCompletionWords = mean(results.map { Double($0.completionWords) }) ?? 0
        coldP50 = Metrics.percentile(results.map(\.coldMilliseconds), 0.5)
        coldP95 = Metrics.percentile(results.map(\.coldMilliseconds), 0.95)
        let warm = results.compactMap(\.warmMilliseconds)
        warmP50 = warm.isEmpty ? nil : Metrics.percentile(warm, 0.5)
        warmP95 = warm.isEmpty ? nil : Metrics.percentile(warm, 0.95)
        let prefillTokens = results.reduce(0) { $0 + $1.promptTokens }
        let prefillTime = results.reduce(0) { $0 + $1.prefillMilliseconds }
        prefillTokensPerSecond = prefillTime > 0 ? Double(prefillTokens) / prefillTime * 1000 : 0
        let steps = results.reduce(0) { $0 + $1.steps }
        stepMilliseconds = steps > 0 ? results.reduce(0) { $0 + $1.searchMilliseconds } / Double(steps) : 0
        meanSteps = mean(results.map { Double($0.steps) }) ?? 0
    }
}
