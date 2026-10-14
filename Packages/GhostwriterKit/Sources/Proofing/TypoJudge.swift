import Foundation

/// Decides with a language model whether a misspelling is a typo worth fixing. The spell checker alone flags
/// names, jargon and words from other languages; the model keeps a word it finds as likely as the guesses.
/// Common misspellings are frequent in a model's training text, so when the model ranks the spell checker's own
/// autocorrection first, any lead is enough to offer it.
public struct TypoJudge: Sendable {
    public enum Verdict: Sendable, Hashable {
        case keep
        case offer(String)
        case autoFix(String)

        public var correction: String? {
            switch self {
            case .keep: nil
            case .offer(let correction), .autoFix(let correction): correction
            }
        }
    }

    public struct Judgment: Sendable, Hashable {
        public var verdict: Verdict
        /// Log probability of the best guess minus that of the typed word, in nats; nil without a model.
        public var margin: Double?
    }

    public static let scoredGuesses = 4

    public var offerMargin: Double
    public var autoFixMargin: Double
    /// How far the best guess must lead the next one to fix automatically: a clearly wrong word with two
    /// plausible fixes (ths: the, this) is offered, not fixed.
    public var autoFixGap: Double

    /// Defaults from `gw-eval --typos`: offer 3 keeps false flags near zero at the same recall; auto-fix 8 with
    /// a gap of 5 is right 98.6 to 99.6% of the time in English, French, German and Spanish.
    public init(offerMargin: Double = 3, autoFixMargin: Double = 8, autoFixGap: Double = 5) {
        self.offerMargin = offerMargin
        self.autoFixMargin = autoFixMargin
        self.autoFixGap = autoFixGap
    }

    /// - Parameter score: The log probability of the text, a candidate word followed by the same suffix for every
    ///   candidate, as the continuation of the text before the word. Nil when no model is loaded.
    public func judge(
        _ misspelling: Misspelling, score: (@Sendable (String) async throws -> Double)?
    ) async -> Judgment {
        guard let first = misspelling.guesses.first else { return Judgment(verdict: .keep, margin: nil) }
        guard let score else { return Judgment(verdict: .offer(first), margin: nil) }
        do {
            let typed = try await score(misspelling.word)
            var scored: [(word: String, logprob: Double)] = []
            for guess in misspelling.guesses.prefix(Self.scoredGuesses) {
                scored.append((guess, try await score(guess)))
            }
            scored.sort { $0.logprob > $1.logprob }
            guard let best = scored.first else { return Judgment(verdict: .keep, margin: nil) }
            let margin = best.logprob - typed
            let lead = scored.count > 1 ? best.logprob - scored[1].logprob : .infinity
            let verdict: Verdict = if margin >= autoFixMargin, lead >= autoFixGap {
                .autoFix(best.word)
            } else if margin >= offerMargin || (margin > 0 && best.word == misspelling.correction) {
                .offer(best.word)
            } else {
                .keep
            }
            return Judgment(verdict: verdict, margin: margin)
        } catch is CancellationError {
            return Judgment(verdict: .keep, margin: nil)
        } catch {
            return Judgment(verdict: .offer(first), margin: nil)
        }
    }
}
