import Testing
@testable import Actions

@Suite struct ProofreadEdits {
    @Test func replacesFromTheFirstChangeToTheCaret() {
        let proofread = Proofread(original: "I recieve teh mail", corrected: "I receive the mail")
        #expect(proofread.deleteCount == 13)
        #expect(proofread.insertion == "eive the mail")
    }

    @Test func revertingRestoresTheOriginal() {
        let proofread = Proofread(original: "their going home", corrected: "they're going home")
        let reverted = proofread.reverted
        #expect(reverted.deleteCount == proofread.corrected.count - 3)
        #expect(String(proofread.corrected.dropLast(reverted.deleteCount)) + reverted.insertion == proofread.original)
    }

    @Test func countsGraphemeClustersNotScalars() {
        let proofread = Proofread(original: "nice 👍🏽 teh", corrected: "nice 👍🏽 the")
        #expect(proofread.deleteCount == 2)
        #expect(proofread.insertion == "he")
    }

    @Test func unchangedTextNeedsNoEdit() {
        let proofread = Proofread(original: "All good.", corrected: "All good.")
        #expect(proofread.isUnchanged)
        #expect(proofread.deleteCount == 0)
        #expect(proofread.insertion.isEmpty)
        #expect(proofread.changes.isEmpty)
    }

    @Test func modelOutputKeepsTheOriginalWhitespace() {
        let proofread = Proofread(original: "  teh cat \n", modelOutput: "The cat.")
        #expect(proofread.corrected == "  The cat. \n")
    }
}

@Suite struct ProofreadChanges {
    @Test func pairsReplacedWords() {
        let changes = Proofread(original: "I recieve teh mail today", corrected: "I receive the mail today").changes
        #expect(changes == [.init(old: "recieve teh", new: "receive the")])
    }

    @Test func listsSeparateChangesInOrder() {
        let changes = Proofread(original: "teh cat sat on teh mat", corrected: "the cat sat on the mat").changes
        #expect(changes == [.init(old: "teh", new: "the"), .init(old: "teh", new: "the")])
    }

    @Test func reportsInsertionsAndRemovals() {
        #expect(Proofread(original: "I going", corrected: "I am going").changes == [.init(old: "", new: "am")])
        #expect(Proofread(original: "the the cat", corrected: "the cat").changes == [.init(old: "the", new: "")])
    }

    @Test func whitespaceOnlyChangesListNoWords() {
        let proofread = Proofread(original: "a  b", corrected: "a b")
        #expect(!proofread.isUnchanged)
        #expect(proofread.changes.isEmpty)
    }

    @Test func flagsRewrites() {
        #expect(Proofread(original: "can you send me the file", corrected: "Sure, here is the file you asked for").rewritesTooMuch)
        #expect(Proofread(original: "whats the capital of france", corrected: "The capital of France is Paris.").rewritesTooMuch)
    }

    @Test func allowsManyFixesInASloppySentence() {
        let proofread = Proofread(
            original: "i recieve teh mail yesterday and it were late",
            corrected: "I received the mail yesterday, and it was late."
        )
        #expect(!proofread.rewritesTooMuch)
    }

    @Test func allowsFewFixesInShortText() {
        #expect(!Proofread(original: "teh cat", corrected: "the cat.").rewritesTooMuch)
    }
}
