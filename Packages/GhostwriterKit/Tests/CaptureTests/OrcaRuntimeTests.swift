import Testing
@testable import Capture

@Suite struct OrcaRuntimeTests {
    private typealias Tracker = OrcaRuntime.TypingTracker

    @Test func firstReadLeavesTheChoiceToOrca() {
        var tracker = Tracker()
        #expect(tracker.update(["first": "", "left": "left behind"]) == nil)
    }

    @Test func picksTheTerminalWhoseDraftChanged() {
        var tracker = Tracker()
        _ = tracker.update(["first": "", "left": "left behind", "typing": ""])
        #expect(tracker.update(["first": "", "left": "left behind", "typing": "h"]) == "typing")
        #expect(tracker.update(["first": "", "left": "left behind", "typing": "he"]) == "typing")
    }

    @Test func keepsTheTerminalWhileNoOtherDraftChanges() {
        var tracker = Tracker()
        _ = tracker.update(["first": "", "typing": ""])
        _ = tracker.update(["first": "", "typing": "hello"])
        #expect(tracker.update(["first": "", "typing": "hello"]) == "typing")
        #expect(tracker.update(["first": "", "typing": ""]) == "typing")
    }

    @Test func followsTypingIntoAnotherTerminal() {
        var tracker = Tracker()
        _ = tracker.update(["one": "", "two": ""])
        _ = tracker.update(["one": "a", "two": ""])
        #expect(tracker.update(["one": "a", "two": "b"]) == "two")
    }

    @Test func picksATerminalOpenedSinceTheLastRead() {
        var tracker = Tracker()
        _ = tracker.update(["one": "left behind"])
        #expect(tracker.update(["one": "left behind", "new": "h"]) == "new")
    }

    @Test func simultaneousChangesKeepThePreviousChoice() {
        var tracker = Tracker()
        _ = tracker.update(["one": "", "two": ""])
        _ = tracker.update(["one": "a", "two": ""])
        #expect(tracker.update(["one": "ab", "two": "x"]) == "one")
    }

    @Test func forgetsAClosedTerminal() {
        var tracker = Tracker()
        _ = tracker.update(["one": "", "two": ""])
        _ = tracker.update(["one": "a", "two": ""])
        #expect(tracker.update(["two": ""]) == nil)
    }
}
