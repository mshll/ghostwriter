import Foundation
import Testing
@testable import Memory

private let reply = "Thanks for sending the figures over. I went through the forecast and the second quarter looks right to me now."
private let otherReply = "One more thing: could we move Thursday's review to the afternoon, so the finance team can join us as well?"
private let draft = "I would also suggest that we schedule a short follow-up meeting next week to confirm the final numbers with everyone."

private func shared(_ length: Int) -> String {
    let paragraph = "The committee reviewed the proposal in detail and agreed to revisit the budget at the next session.\n"
    return String(String(repeating: paragraph, count: length / paragraph.count + 1).prefix(length))
}

@Suite struct FieldWritingTests {
    @Test func aFieldOpenedOnlyToReadStoresNothing() {
        let document = shared(2_000)
        let writing = FieldWriting(baseline: document)
        #expect(writing.excerpt(of: document) == nil)
        #expect(writing.excerpt(of: document + reply) == nil)
    }

    @Test func typingBelowTheMinimumStoresNothing() {
        var writing = FieldWriting(baseline: "")
        writing.typed(FieldWriting.minimumTyped - 1)
        #expect(writing.excerpt(of: reply) == nil)
        writing.typed(1)
        #expect(writing.excerpt(of: reply) == reply)
    }

    @Test func mostlyInsertedTextIsNotStored() {
        var writing = FieldWriting(baseline: "")
        var text = ""
        for word in reply.split(separator: " ") {
            writing.typed(1)
            writing.inserted(String(word.dropFirst()) + " ")
            text += word + " "
        }
        #expect(writing.excerpt(of: text) == nil)
    }

    @Test func insertedTextIsLeftOutOfWhatIsStored() {
        var writing = FieldWriting(baseline: "")
        writing.typed(reply.count)
        writing.inserted(" " + draft)
        writing.typed(otherReply.count + 1)
        let excerpt = writing.excerpt(of: reply + " " + draft + "\n" + otherReply)
        #expect(excerpt == reply + "\n" + otherReply)
    }

    @Test func wordsAcceptedOneAfterAnotherAreLeftOutTogether() {
        var writing = FieldWriting(baseline: "")
        writing.typed(reply.count)
        for word in ["We ", "should ", "meet ", "again ", "soon."] { writing.inserted(word) }
        writing.typed(otherReply.count + 1)
        let excerpt = writing.excerpt(of: reply + " We should meet again soon.\n" + otherReply)
        #expect(excerpt == reply + " \n" + otherReply)
    }

    @Test func textAroundTheEditThatTheUserDidNotChangeIsLeftOut() {
        let thread = "\n\nOn Monday, Sam wrote:\n" + shared(3_000)
        var writing = FieldWriting(baseline: thread)
        writing.typed(reply.count)
        #expect(writing.excerpt(of: reply + thread) == reply)
    }

    @Test func quotedLinesBetweenTheUsersLinesAreDropped() {
        let quoted = "> Can you check the forecast?\n> And the review date?\n"
        var writing = FieldWriting(baseline: quoted)
        writing.typed(reply.count + otherReply.count + 2)
        let answered = "> Can you check the forecast?\n" + reply + "\n> And the review date?\n" + otherReply + "\n"
        #expect(writing.excerpt(of: answered) == reply + "\n" + otherReply)
    }

    @Test func aLargeFieldStoresAtMostTheCap() throws {
        let typed = shared(200_000)
        var writing = FieldWriting(baseline: "")
        writing.typed(typed.count)
        let excerpt = try #require(writing.excerpt(of: typed))
        #expect(excerpt.count <= FieldWriting.maximumLength)
        #expect(excerpt.count > FieldWriting.maximumLength - 200)
        #expect(typed.trimmingCharacters(in: .newlines).hasSuffix(excerpt))
    }

    @Test func anEditInsideALargeSingleLineFieldStoresTheEditWithLimitedContext() throws {
        let line = shared(200_000).replacingOccurrences(of: "\n", with: " ")
        let middle = line.index(line.startIndex, offsetBy: 100_000)
        var writing = FieldWriting(baseline: line)
        writing.typed(reply.count)
        let excerpt = try #require(writing.excerpt(of: line[..<middle] + reply + line[middle...]))
        #expect(excerpt.contains(reply))
        #expect(excerpt.count <= FieldWriting.maximumLength)
    }

    @Test func aNewVisitNeedsNewTypingButKeepsEarlierWriting() {
        var writing = FieldWriting(baseline: "")
        writing.typed(reply.count)
        writing.refocused()
        #expect(writing.excerpt(of: reply) == nil)
        writing.typed(otherReply.count + 1)
        #expect(writing.excerpt(of: reply + "\n" + otherReply) == reply + "\n" + otherReply)
    }
}
