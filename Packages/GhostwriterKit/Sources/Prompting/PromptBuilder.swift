import Foundation
import GWCore

public struct PromptBuilder: Sendable {
    public var counter: any TokenCounting
    public var budgets: PromptBudgets
    public var includeAfterText = true
    public var timeZone = TimeZone.autoupdatingCurrent

    public init(counter: any TokenCounting, budgets: PromptBudgets = PromptBudgets()) {
        self.counter = counter
        self.budgets = budgets
    }

    public func build(_ context: PromptContext) -> BuiltPrompt {
        let typed = PartialWord.split(context.textBefore)
        let language = LanguageDetector.language(ofTextBefore: context.textBefore)
        let budgets = budgets.adjusted(for: context.mode)
        let fitter = SectionFitter(counter: counter)

        let afterSource = context.mode == .inline && includeAfterText
            ? Self.afterCaretExcerpt(context.textAfter) : ""
        let examples = context.examples.map(Self.trimmed).filter { !$0.isEmpty }
        let exampleTokens = examples.map { fitter.measure($0[...], limit: budgets.examples) }
        let separatorTokens = counter.countTokens(PromptText.exampleSeparator)
        let examplesDemand = exampleTokens.reduce(0, +) + separatorTokens * max(0, examples.count - 1)
        let clipboard = Self.trimmed(context.clipboard ?? "")
        let screen = Self.trimmed(context.screenText ?? "")

        let allocation = BudgetAllocator.allocate(
            demands: [
                budgets.before,
                budgets.after,
                min(examplesDemand, budgets.examples),
                min(fitter.measure(screen[...], limit: budgets.screen), budgets.screen),
                min(fitter.measure(clipboard[...], limit: budgets.clipboard), budgets.clipboard),
            ],
            priorities: [0, 0, 1, 1, 2],
            total: budgets.total,
            step: budgets.step
        )

        let instructions = fitter.fit(Self.trimmed(context.instructions ?? "")[...], budget: budgets.instructions, keep: .start)
        let environment = EnvironmentLines.make(for: context)
        let volatile = EnvironmentLines.volatile(for: context, language: language, timeZone: timeZone)
        let pickedExamples = Self.pack(examples, tokens: exampleTokens, separatorTokens: separatorTokens, budget: allocation[2], fitter: fitter)
        let screenSection = fitter.fit(screen[...], budget: allocation[3], keep: .start)
        let clipboardSection = fitter.fit(clipboard[...], budget: allocation[4], keep: .start)
        let after = fitter.fit(afterSource[...], budget: allocation[1], keep: .start)
        let before = fitter.fit(Self.plainTrailingSpaces(typed.head).drop(while: \.isWhitespace), budget: allocation[0], keep: .end)

        var text = PromptText.preamble
        if !instructions.isEmpty { text += PromptText.instructionsLabel + instructions + "\n\n" }
        if !environment.isEmpty { text += environment.joined(separator: "\n") + "\n\n" }
        if !pickedExamples.isEmpty {
            text += PromptText.examplesLabel + pickedExamples.joined(separator: PromptText.exampleSeparator) + "\n\n"
        }
        if !clipboardSection.isEmpty { text += PromptText.clipboardLabel + clipboardSection + "\n\n" }
        if !screenSection.isEmpty { text += PromptText.screenLabel + screenSection + "\n\n" }
        if !after.isEmpty { text += PromptText.afterLabel + after + "\n\n" }
        if !volatile.isEmpty { text += volatile.joined(separator: "\n") + "\n\n" }
        text += after.isEmpty ? PromptText.typingLabel : PromptText.typingMidLineLabel
        text += before

        return BuiltPrompt(
            text: text,
            partialWord: String(typed.partial),
            language: language,
            includesDate: EnvironmentLines.includesDate(context, language: language)
        )
    }

    /// Rich text editors report a space typed at the end as a no-break space. As a plain one it goes to the
    /// engine as typed, so no suggestion starts with another space.
    static func plainTrailingSpaces(_ text: Substring) -> Substring {
        let run = text.reversed().prefix { $0 == " " || $0 == "\u{00A0}" }.count
        guard text.suffix(run).contains("\u{00A0}") else { return text }
        return text.dropLast(run) + String(repeating: " ", count: run)
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func afterCaretExcerpt(_ textAfter: String) -> String {
        let lines = textAfter.split(maxSplits: 2, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let current = lines.first, !current.allSatisfy(\.isWhitespace) else { return "" }
        return trimmed(lines.prefix(2).joined(separator: "\n"))
    }

    static func pack(
        _ examples: [String], tokens: [Int], separatorTokens: Int, budget: Int, fitter: SectionFitter
    ) -> [String] {
        guard budget > 0 else { return [] }
        var picked: [String] = []
        var used = 0
        for (example, cost) in zip(examples, tokens) {
            let total = cost + (picked.isEmpty ? 0 : separatorTokens)
            if used + total <= budget {
                picked.append(example)
                used += total
            }
        }
        if picked.isEmpty, let first = examples.first {
            let cut = fitter.fit(first[...], budget: budget, keep: .start)
            if !cut.isEmpty { picked = [cut] }
        }
        return picked
    }
}

extension PromptBudgets {
    func adjusted(for mode: PromptMode) -> PromptBudgets {
        guard mode == .draft else { return self }
        var draft = self
        draft.before = before * 3
        draft.examples = examples / 2
        draft.clipboard = clipboard / 2
        draft.total = total + before * 2
        return draft
    }
}

enum PromptText {
    static let preamble =
        "I am typing on my Mac. My text comes last; before it is some context, which may or may not be relevant.\n\n"
    /// The preamble's second sentence, which drafts echo after rewording the first.
    static let preambleTail = "My text comes last; before it is"
    static let instructionsLabel = "Notes about me and my writing:\n"
    static let examplesLabel = "Passages I wrote earlier:\n"
    static let exampleSeparator = "\n\n---\n\n"
    static let separatorStop = "\n\n---\n"
    static let clipboardLabel = "Text I recently copied:\n"
    static let screenLabel = "Text on my screen:\n"
    static let afterLabel = "Text that comes right after my cursor:\n"
    static let typingLabel = "What I am writing:\n\n"
    static let typingMidLineLabel = "What I am writing, up to my cursor:\n\n"

    static let labels = [
        instructionsLabel, examplesLabel, clipboardLabel, screenLabel, afterLabel, typingLabel, typingMidLineLabel,
    ]
}
