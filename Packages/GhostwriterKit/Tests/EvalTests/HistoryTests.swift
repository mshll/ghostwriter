import Foundation
import GWCore
import Inference
import Memory
import Prompting
import Testing
@testable import gw_eval

struct QuarterCounter: TokenCounting {
    func countTokens(_ text: String) -> Int { (text.count + 3) / 4 }
}

let invoice = "The invoice for the design work is attached. Please confirm the payment date. Please confirm the payment date by Friday so accounting can close the month."
let garden = "Gardening this spring went well: tomatoes, basil and peppers are thriving in the raised beds near the fence all summer."

func historyFile(_ sessions: [(id: String, bundle: String, text: String)]) throws -> URL {
    let date = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-24 * 3_600))
    let lines = try sessions.map { session in
        let object: [String: Any] = ["id": session.id, "bundle": session.bundle, "lang": "en", "date": date, "text": session.text]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    let url = URL.temporaryDirectory.appending(path: "history-\(UUID().uuidString).jsonl")
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

func personalization(exampleLimit: Int = 2, biasStrength: Double = 1.5) throws -> Personalization {
    let url = try historyFile([("a", "com.apple.mail", invoice), ("b", "com.apple.Notes", garden)])
    defer {
        do { try FileManager.default.removeItem(at: url) } catch { Issue.record(error) }
    }
    return Personalization(memory: try Personalization.load(url), exampleLimit: exampleLimit, biasStrength: biasStrength)
}

let row = Row(id: "r1", app: "Mail", kind: "email", before: "Quick question about the invoice and the payment ", after: "", bundle: "com.apple.mail")

@Suite struct HistoryOptions {
    @Test func historyDefaultsToTheAppsSettings() throws {
        let options = try Options.parse(["--set", "x.jsonl", "--history", "h.jsonl"])
        #expect(options.history?.lastPathComponent == "h.jsonl")
        #expect(options.exampleLimit == 2)
        #expect(options.biasStrength == 1.5)
        #expect(options.ranking == ExampleRanking())
    }

    @Test func flagsOverrideEachSetting() throws {
        let options = try Options.parse([
            "--set", "x.jsonl", "--history", "h.jsonl", "--examples", "0", "--bias-strength", "0.75",
            "--same-app-boost", "1", "--recency-boost", "0.5",
        ])
        #expect(options.exampleLimit == 0)
        #expect(options.biasStrength == 0.75)
        #expect(options.ranking.sameAppBoost == 1)
        #expect(options.ranking.recencyBoost == 0.5)
    }

    @Test func personalizingFlagsNeedHistory() {
        #expect(throws: UsageError.self) { try Options.parse(["--set", "x.jsonl", "--bias-strength", "1"]) }
        #expect(throws: UsageError.self) { try Options.parse(["--set", "x.jsonl", "--history", "h.jsonl", "--examples", "-1"]) }
    }

    @Test func noHistoryMeansNoPersonalization() throws {
        #expect(try Options.parse(["--set", "x.jsonl"]).personalization() == nil)
    }
}

@Suite struct HistoryRequests {
    @Test func examplesComeFromRelatedWriting() throws {
        #expect(try personalization().examples(for: row) == [invoice])
    }

    @Test func zeroExamplesTurnsThemOff() throws {
        #expect(try personalization(exampleLimit: 0).examples(for: row).isEmpty)
    }

    @Test func biasCarriesTheFollowersAndStrength() throws {
        let bias = try #require(try personalization(biasStrength: 0.75).bias(language: "en"))
        #expect(bias.strength == 0.75)
        #expect(bias.followers["payment"]?["date"] != nil)
    }

    @Test func zeroStrengthTurnsTheBiasOff() throws {
        #expect(try personalization(biasStrength: 0).bias(language: "en") == nil)
    }

    @Test func theRequestCarriesExamplesAndBias() throws {
        var builder = PromptBuilder(counter: QuarterCounter())
        builder.includeAfterText = true
        let harness = Harness(
            engine: CompletionEngine(), builder: builder, options: try Options.parse(["--set", "x.jsonl"]),
            personalization: try personalization()
        )
        let request = try harness.request(for: row, before: row.before)
        #expect(request.prompt.contains("so accounting can close the month"))
        #expect(request.bias?.strength == 1.5)

        let plain = Harness(engine: CompletionEngine(), builder: builder, options: harness.options, personalization: nil)
        let baseline = try plain.request(for: row, before: row.before)
        #expect(!baseline.prompt.contains("accounting"))
        #expect(baseline.bias == nil)
    }
}
