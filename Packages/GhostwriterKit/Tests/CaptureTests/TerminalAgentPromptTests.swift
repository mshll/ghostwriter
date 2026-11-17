import Foundation
import Testing
@testable import Capture

@Suite struct TerminalAgentPromptTests {
    private static let rule = String(repeating: "─", count: 80)
    private static let output = """
    ⏺ I moved the default into one place and the tests pass.

      Want me to open a pull request next?

    """

    private static func screen(_ box: [String], status: Bool = true, footer: Bool = true) -> String {
        var lines = output.components(separatedBy: "\n")
        if status { lines.append(String(repeating: " ", count: 60) + "◐ medium · /effort") }
        lines += [rule] + box + [rule]
        if footer { lines += ["  ? for shortcuts", "  ⏵⏵ auto mode on (shift+tab to cycle)", ""] }
        return lines.joined(separator: "\n")
    }

    private static func offset(of needle: String, in screen: String) -> Int {
        (screen as NSString).range(of: needle, options: .backwards).location
    }

    private static func belowBox(_ screen: String) -> Int {
        offset(of: "  ? for shortcuts", in: screen)
    }

    @Test func placeholderWithTheCursorAtTheDraftStartIsEmpty() throws {
        let screen = Self.screen(["❯ Try \"how do I log an error?\""])
        let cursor = Self.offset(of: "Try", in: screen)
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: cursor))
        #expect(prompt.textBefore.isEmpty)
        #expect(prompt.textAfter.isEmpty)
        #expect(prompt.anchor == NSRange(location: cursor - 1, length: 1))
        #expect(prompt.draftStart == cursor)
    }

    @Test func noBreakSpaceAfterThePromptGlyph() throws {
        let screen = Self.screen(["❯\u{00A0}Fix the failing test in the parser"])
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: nil))
        #expect(prompt.textBefore == "Fix the failing test in the parser")
    }

    @Test func oneLineDraftDropsTheDrawnCaretCell() throws {
        let screen = Self.screen(["❯ Refactor the settings pane "])
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: Self.belowBox(screen)))
        #expect(prompt.textBefore == "Refactor the settings pane")
        #expect(prompt.textAfter.isEmpty)
        #expect(prompt.anchor == NSRange(location: Self.offset(of: "pane ", in: screen) + 3, length: 1))
    }

    @Test func typedTrailingSpaceSurvivesTheCaretCell() throws {
        let screen = Self.screen(["❯ fix the  "])
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: nil))
        #expect(prompt.textBefore == "fix the ")
    }

    @Test func softWrappedLinesJoinWithASpace() throws {
        let screen = Self.screen([
            "❯ Refactor the settings pane so the scope picker sits above the list and",
            "  keep the empty state copy short. Then check that ",
        ])
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: Self.belowBox(screen)))
        #expect(prompt.textBefore == "Refactor the settings pane so the scope picker sits above the list and keep the empty state copy short. Then check that")
        #expect(prompt.anchor == NSRange(location: Self.offset(of: "t ", in: screen), length: 1))
        #expect(prompt.draftStart == Self.offset(of: "Refactor", in: screen))
    }

    @Test func aWordBrokenAtTheFullWidthJoinsWithoutASpace() throws {
        let rule = String(repeating: "─", count: 20)
        let screen = [rule, "❯ " + String(repeating: "a", count: 18), "  bbbb ", rule].joined(separator: "\n")
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: nil))
        #expect(prompt.textBefore == String(repeating: "a", count: 18) + "bbbb")
    }

    @Test func caretCellWrappedOntoItsOwnLineAddsNothing() throws {
        let screen = Self.screen(["❯ ask about the release notes", "   "])
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: nil))
        #expect(prompt.textBefore == "ask about the release notes")
    }

    @Test func cursorInsideTheDraftSplitsIt() throws {
        let screen = Self.screen(["❯ write the tests first"])
        let cursor = Self.offset(of: " tests", in: screen)
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: cursor))
        #expect(prompt.textBefore == "write the")
        #expect(prompt.textAfter == " tests first")
    }

    @Test func roundedBoxJoinsItsLinesInsideTheBorders() throws {
        let screen = """
        Done. The build is green.

        ╭────────────────────────────╮
        │ > Fix the login bug in     │
        │   the auth module          │
        ╰────────────────────────────╯
          ~/project   model: default
        """
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: nil))
        #expect(prompt.textBefore == "Fix the login bug in the auth module")
        #expect(prompt.transcript == "Done. The build is green.")
        #expect(prompt.anchor == NSRange(location: Self.offset(of: "e          │", in: screen), length: 1))
    }

    @Test func optionMenuIsNotAPrompt() {
        let screen = """
        \(Self.rule)
         Accessing workspace:

         Quick safety check: Is this a project you created or one you trust?

         ❯ No, exit
           Yes, I trust this folder

         Enter to confirm · Esc to cancel

        """
        #expect(TerminalAgentPrompt.find(in: screen, cursor: nil) == nil)
    }

    @Test func numberedOptionBetweenRulesIsNotAPrompt() {
        let screen = [Self.rule, "❯ 1. Yes", "  2. No", Self.rule].joined(separator: "\n")
        #expect(TerminalAgentPrompt.find(in: screen, cursor: nil) == nil)
    }

    @Test func shellPromptIsNotAPrompt() {
        let screen = "Last login: Tue on ttys004\n\n~ \n❯ git status\n"
        #expect(TerminalAgentPrompt.find(in: screen, cursor: nil) == nil)
    }

    @Test func shellPromptAfterAnOldBoxIsNotAPrompt() {
        let screen = Self.screen(["❯ an old draft "]) + "\n~ \n❯ ls"
        #expect(TerminalAgentPrompt.find(in: screen, cursor: nil) == nil)
    }

    @Test func shellPromptRightAboveABoxStaysInTheTranscript() throws {
        let screen = ["~ ", "❯ agent", Self.rule, "❯ hello there ", Self.rule].joined(separator: "\n")
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: nil))
        #expect(prompt.textBefore == "hello there")
        #expect(prompt.transcript == "~\n❯ agent")
    }

    @Test func boxWithoutAClosingRuleIsNotAPrompt() {
        let screen = [Self.rule, "❯ half drawn", "  "].joined(separator: "\n")
        #expect(TerminalAgentPrompt.find(in: screen, cursor: nil) == nil)
    }

    @Test func transcriptDropsRulesAndTheStatusLine() throws {
        let prompt = try #require(TerminalAgentPrompt.find(in: Self.screen(["❯ next "]), cursor: nil))
        #expect(prompt.transcript == "⏺ I moved the default into one place and the tests pass.\n\n  Want me to open a pull request next?")
    }

    @Test func longScrollbackReadsOnlyTheLastRows() throws {
        let scrollback = (0..<5_000).map { "line \($0)" }.joined(separator: "\n")
        let screen = scrollback + "\n" + Self.screen(["❯ summarize the log "], status: false)
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: nil))
        #expect(prompt.textBefore == "summarize the log")
        let transcriptLines = prompt.transcript.components(separatedBy: "\n")
        #expect(transcriptLines.count < TerminalAgentPrompt.scannedRows)
        #expect(!prompt.transcript.contains("line 0\n"))
        #expect(transcriptLines.contains("line 4999"))
    }

    @Test func emptyBoxWithTheMarkerAloneIsEmpty() throws {
        let screen = Self.screen(["❯"])
        let prompt = try #require(TerminalAgentPrompt.find(in: screen, cursor: nil))
        #expect(prompt.textBefore.isEmpty)
        #expect(prompt.draftStart == nil)
    }

    @Test func wideCharactersFillTheLineByColumns() {
        #expect(TerminalAgentPrompt.columns("日本語") == 6)
        #expect(TerminalAgentPrompt.columns("abc") == 3)
    }
}
