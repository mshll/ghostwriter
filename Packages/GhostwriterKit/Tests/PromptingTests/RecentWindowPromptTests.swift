import Foundation
import GWCore
import Testing
@testable import Prompting

@Suite struct RecentWindowPrompt {
    private let page = (1...200).map { "Line \($0) of the product page." }.joined(separator: "\n")

    private func window(_ text: String, app: String = "Safari", title: String? = "Trail Tent 2", host: String? = "shop.example")
        -> PromptContext.RecentWindow {
        PromptContext.RecentWindow(appName: app, title: title, host: host, text: text)
    }

    private func section(of prompt: String) throws -> String {
        let start = try #require(prompt.range(of: PromptText.recentWindowLabelStart)?.lowerBound)
        let body = try #require(prompt[start...].range(of: ":\n")?.upperBound)
        let end = try #require(prompt[body...].range(of: "\n\n")?.lowerBound)
        return String(prompt[body..<end])
    }

    @Test func sitsBetweenTheExamplesAndTheClipboard() throws {
        let text = makeBuilder().build(PromptContext(
            appName: "Notes", examples: ["An earlier passage I wrote."], clipboard: "Copied text",
            screenText: "Screen text", recentWindow: window("A tent for two people."), textBefore: englishParagraph
        )).text
        let markers = [
            PromptText.examplesLabel, "Text in the window I just left (Safari, \"Trail Tent 2\", shop.example):\n"
                + "A tent for two people.\n\n",
            PromptText.clipboardLabel, PromptText.screenLabel, PromptText.typingLabel,
        ]
        let offsets = try markers.map { marker in
            try #require(text.range(of: marker)?.lowerBound, "missing \(marker)")
        }
        #expect(offsets == offsets.sorted())
    }

    @Test func headerLeavesOutATitleThatOnlyRepeatsTheApp() {
        let header = PromptText.recentWindowLabel(window("x", app: "Notes", title: "notes", host: nil))
        #expect(header == "Text in the window I just left (Notes):\n")
    }

    @Test func keepsTheStartOfTheWindowUpToItsBudget() throws {
        let prompt = makeBuilder().build(PromptContext(appName: "Notes", recentWindow: window(page), textBefore: "Hi ")).text
        let kept = try section(of: prompt)
        #expect(kept.hasPrefix("Line 1 of the product page.\nLine 2 "))
        #expect(QuarterCounter().countTokens(kept) <= PromptBudgets().recentWindow)
        #expect(QuarterCounter().countTokens(kept) > PromptBudgets().recentWindow / 2)
    }

    @Test func textFittedOnceBuildsTheSamePrompt() {
        let builder = makeBuilder()
        let fitted = builder.fitted(window(page))
        #expect(QuarterCounter().countTokens(fitted.text) <= PromptBudgets().recentWindow)
        func prompt(_ recent: PromptContext.RecentWindow) -> String {
            builder.build(PromptContext(appName: "Notes", recentWindow: recent, textBefore: "Hi ")).text
        }
        #expect(prompt(fitted) == prompt(window(page)))
    }

    @Test func getsOnlyWhatTheWindowTextAndExamplesLeave() throws {
        let screen = String(repeating: "Text near the caret in the note. ", count: 120)
        let examples = [String(repeating: "A passage I wrote before. ", count: 80)]
        let prompt = makeBuilder().build(PromptContext(
            appName: "Notes", examples: examples, screenText: screen, recentWindow: window(page), textBefore: "Hi "
        )).text
        let tokens = QuarterCounter().countTokens(try section(of: prompt))
        #expect(tokens > 0 && tokens <= 160)
    }

    @Test func isLeftOutWhenTheClipboardTakesTheLastOfTheBudget() {
        let screen = String(repeating: "Text near the caret in the note. ", count: 120)
        let examples = [String(repeating: "A passage I wrote before. ", count: 80)]
        let clipboard = String(repeating: "Copied words. ", count: 120)
        let prompt = makeBuilder().build(PromptContext(
            appName: "Notes", examples: examples, clipboard: clipboard, screenText: screen, recentWindow: window(page),
            textBefore: "Hi "
        )).text
        #expect(!prompt.contains(PromptText.recentWindowLabelStart))
    }

    @Test func modelOutputStopsAtItsHeader() {
        #expect(BuiltPrompt.stopStrings.contains("Text in the window I just left"))
    }
}
