import Foundation
import GWCore
import Inference
import Prompting

struct Options {
    enum Task { case evaluate, bench, score, typing, swap, pause, typos, proofread }
    enum Backend { case llama, foundation }

    var backend = Backend.llama

    var model = ModelCatalog.curated[0].localURL
    var set: URL?
    var variant = "default"
    var beams = 6
    var topK = 20
    var maxWords = CompletionLength.medium.maxWords
    var json: URL?
    var limit: Int?
    var verbose = false
    var warm = true
    var download: String?
    var afterSection = true
    var screen = true
    var budgets = PromptBudgets()
    var promptVariant = PromptVariant.standard
    var task = Task.evaluate
    var stopStrings = true
    var draft = false
    var tuning = SearchTuning()
    var typingSpeed: Double?
    var engineMode: EngineMode?
    var firstShown = false
    var engine = EngineConfig()
    var swapMode = SwapMode.staged
    var swapAt = 2
    var readLag = 0.0
    var settle: Double? = ShownSuggestion.settleMilliseconds
    var pause = 1500.0
    var pauseTyped = 6

    /// The app's word cap for drafts; the default for `--mode draft`.
    static let draftWords = 80

    static let usage = """
        usage: gw-eval --set <jsonl> [--model <gguf>] [--variant <name>] [--beams N] [--top-k N] [--max-words N (inline: medium length, draft: 80)]
                       [--length-penalty X] [--floor X] [--confidence X] [--midline-confidence X] [--early-stop X] [--narrow-after N] [--narrow-stop P]
                       [--midline-bonus X] [--midline-margin X] [--midline-tokens N] [--midline-candidates N] [--no-echo-guard]
                       [--limit N] [--no-warm] [--no-after-section] [--no-screen] [--screen-tokens N] [--total-tokens N] [--prompt standard|bare|no-preamble|no-environment] [--no-stop-strings] [--mode inline|draft] [--verbose] [--json out.json]
                       [--first-shown]   (score the first suggestion streamed, not the final one)
               gw-eval --bench --set <jsonl> [--model <gguf>] [--beams N]
               gw-eval --score --set <jsonl> [--model <gguf>] [--limit N] [--json out.json]   (bits per character of the truth)
               gw-eval --typing --set <jsonl> [--model <gguf>] [--limit N] [--json out.json]  (keystrokes saved when typing the truth)
                       [--typing-speed <characters per second>]   (suggestions that arrive after the next keystroke are late)
                       [--engine continuous|economy|oneshot]   (clocked keystrokes through the engine's suggestion stream)
                       [--read-lag <ms>]   (with --engine continuous|economy: typed text reaches the engine, and new suggestions the screen, at the field read)
                       [--settle <ms>] [--keep-shown]   (a finished search replaces the shown suggestion this long after a key press, or never)
               gw-eval --typing --foundation --set <jsonl> [--limit N] [--verbose]   (the same with Apple's on-device model)
               gw-eval --pause <ms> --set <jsonl> [--pause-typed N (6)] [--typing-speed N] [--read-lag <ms>] [--settle <ms>] [--keep-shown] [--json out.json]
                       (pause test: type the last N characters of each row's text, wait, take the suggestion shown)
               gw-eval --swap none|direct|staged --set <jsonl with screen text> [--model <gguf>] [--limit N] [--typing-speed N] [--swap-at N] [--staging-chunk N]
                       (real-time typing while the screen text lands: how long keystrokes wait for a matching suggestion)
               gw-eval --typos <jsonl> [--model <gguf>] [--limit N] [--verbose] [--json out.json]
                       (spell checker and model judge on word rows of eval/data/typos.jsonl: offers, auto-fixes, false flags)
               gw-eval --proofread <jsonl> [--limit N] [--verbose] [--json out.json]   (fix grammar with Apple's on-device model on sentence rows)
               gw-eval --download <catalog id>
        variants: \(Variant.names.joined(separator: ", "))
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var overrides: [(inout SearchTuning) -> Void] = []
        var iterator = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw UsageError("\(flag) needs a value") }
            return next
        }
        func number<T: LosslessStringConvertible>(_ flag: String) throws -> T {
            let text = try value(flag)
            guard let parsed = T(text) else { throw UsageError("\(flag): '\(text)' is not a number") }
            return parsed
        }
        var maxWords: Int?
        while let flag = iterator.next() {
            switch flag {
            case "--model": options.model = URL(filePath: try value(flag))
            case "--set": options.set = URL(filePath: try value(flag))
            case "--variant": options.variant = try value(flag)
            case "--beams": options.beams = try number(flag)
            case "--top-k": options.topK = try number(flag)
            case "--max-words": maxWords = try number(flag)
            case "--json": options.json = URL(filePath: try value(flag))
            case "--limit": options.limit = try number(flag)
            case "--verbose": options.verbose = true
            case "--no-warm": options.warm = false
            case "--no-after-section": options.afterSection = false
            case "--no-screen": options.screen = false
            case "--screen-tokens": options.budgets.screen = try number(flag)
            case "--total-tokens": options.budgets.total = try number(flag)
            case "--prompt":
                let name = try value(flag)
                guard let variant = PromptVariant(rawValue: name) else { throw UsageError("unknown prompt variant \(name)") }
                options.promptVariant = variant
            case "--bench": options.task = .bench
            case "--score": options.task = .score
            case "--typing": options.task = .typing
            case "--typos":
                options.task = .typos
                options.set = URL(filePath: try value(flag))
            case "--proofread":
                options.task = .proofread
                options.set = URL(filePath: try value(flag))
            case "--typing-speed":
                let x: Double = try number(flag)
                guard x > 0 else { throw UsageError("--typing-speed must be above 0") }
                options.typingSpeed = x
            case "--engine":
                let name = try value(flag)
                guard let mode = EngineMode(rawValue: name) else { throw UsageError("unknown engine \(name)") }
                options.engineMode = mode
            case "--foundation": options.backend = .foundation
            case "--settle":
                let x: Double = try number(flag)
                guard x >= 0 else { throw UsageError("--settle must be 0 or more") }
                options.settle = x
            case "--keep-shown": options.settle = nil
            case "--pause":
                let x: Double = try number(flag)
                guard x >= 0 else { throw UsageError("--pause must be 0 or more") }
                options.task = .pause
                options.pause = x
            case "--pause-typed":
                let x: Int = try number(flag)
                guard x > 0 else { throw UsageError("--pause-typed must be above 0") }
                options.pauseTyped = x
            case "--first-shown": options.firstShown = true
            case "--swap":
                let name = try value(flag)
                guard let mode = SwapMode(rawValue: name) else { throw UsageError("unknown swap mode \(name)") }
                options.task = .swap
                options.swapMode = mode
            case "--read-lag":
                let x: Double = try number(flag)
                guard x >= 0 else { throw UsageError("--read-lag must be 0 or more") }
                options.readLag = x
            case "--swap-at":
                let x: Int = try number(flag)
                guard x > 0 else { throw UsageError("--swap-at must be above 0") }
                options.swapAt = x
            case "--staging-chunk":
                let x: Int = try number(flag)
                guard x > 0 else { throw UsageError("--staging-chunk must be above 0") }
                options.engine.stagingChunk = x
            case "--no-stop-strings": options.stopStrings = false
            case "--mode":
                switch try value(flag) {
                case "inline": options.draft = false
                case "draft": options.draft = true
                case let other: throw UsageError("unknown mode \(other)")
                }
            case "--download": options.download = try value(flag)
            case "--length-penalty":
                let x: Double = try number(flag)
                overrides.append { $0.lengthPenalty = x }
            case "--floor":
                let x: Double = try number(flag)
                overrides.append { $0.probabilityFloor = x }
            case "--confidence":
                let x: Double = try number(flag)
                overrides.append { $0.confidenceRatio = x }
            case "--midline-bonus":
                let x: Double = try number(flag)
                overrides.append { $0.midLineWordBonus = x }
            case "--midline-tokens":
                let x: Int = try number(flag)
                overrides.append { $0.midLineContextTokens = x }
            case "--midline-confidence":
                let x: Double = try number(flag)
                overrides.append { $0.midLineConfidenceRatio = x }
            case "--narrow-after":
                let x: Int = try number(flag)
                overrides.append { $0.narrowAfterSteps = x < 0 ? nil : x }
            case "--narrow-stop":
                let x: Double = try number(flag)
                overrides.append { $0.narrowedStopProbability = x }
            case "--early-stop":
                let x: Double = try number(flag)
                overrides.append { $0.earlyStopMargin = x < 0 ? nil : x }
            case "--no-echo-guard":
                overrides.append { $0.blocksEchoes = false }
            case "--midline-candidates":
                let x: Int = try number(flag)
                overrides.append { $0.midLineCandidates = x }
            case "--midline-margin":
                let x: Double = try number(flag)
                overrides.append { $0.midLineMargin = x }
            case "--help", "-h": throw UsageError(nil)
            default: throw UsageError("unknown argument \(flag)")
            }
        }
        options.maxWords = maxWords ?? (options.draft ? Self.draftWords : CompletionLength.medium.maxWords)
        guard let tuning = Variant.tuning(named: options.variant) else { throw UsageError("unknown variant \(options.variant)") }
        options.tuning = tuning
        for override in overrides { override(&options.tuning) }
        guard options.set != nil || options.download != nil else { throw UsageError("--set is required") }
        return options
    }
}

struct UsageError: Error {
    var message: String?
    init(_ message: String?) { self.message = message }
}

enum Variant {
    static let names = ["default", "sum", "mean", "wide", "narrowed", "confidence", "exhaustive"]

    static func tuning(named name: String) -> SearchTuning? {
        var tuning = SearchTuning()
        switch name {
        case "default": break
        case "sum": tuning.lengthPenalty = 0
        case "mean": tuning.lengthPenalty = 1
        case "wide": tuning.midLineConfidenceRatio = 0
        case "narrowed": tuning.narrowAfterSteps = 2
        case "confidence": tuning.confidenceRatio = 0.7
        case "exhaustive": tuning.earlyStopMargin = nil
        default: return nil
        }
        return tuning
    }
}
