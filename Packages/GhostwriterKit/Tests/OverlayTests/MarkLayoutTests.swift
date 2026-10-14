import CoreGraphics
import Testing
@testable import Overlay

@Suite struct MarkLayoutTests {
    private let caret = CGRect(x: 200, y: 100, width: 1, height: 18)

    @Test func strikesTheWordBeforeTheClosingCharacterAndPutsTheChipAtTheCaret() {
        let placement = MarkLayout.typo(caret: caret, wordWidth: 50, closingWidth: 4, chipWidth: 60, direction: .leftToRight)
        #expect(placement.frame == CGRect(x: 146, y: 100, width: 116, height: 18))
        #expect(placement.word == CGRect(x: 0, y: 0, width: 50, height: 18))
        #expect(placement.chip == CGRect(x: 56, y: 0, width: 60, height: 18))
    }

    @Test func mirrorsForRightToLeftText() {
        let placement = MarkLayout.typo(caret: caret, wordWidth: 50, closingWidth: 4, chipWidth: 60, direction: .rightToLeft)
        #expect(placement.frame == CGRect(x: 138, y: 100, width: 116, height: 18))
        #expect(placement.word == CGRect(x: 66, y: 0, width: 50, height: 18))
        #expect(placement.chip == CGRect(x: 0, y: 0, width: 60, height: 18))
    }

    @Test func statusSitsBelowTheLine() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = MarkLayout.status(size: CGSize(width: 90, height: 22), caret: caret, screen: screen)
        #expect(frame == CGRect(x: 196, y: 124, width: 90, height: 22))
    }

    @Test func statusMovesAboveTheLineAtTheScreenBottomAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 130)
        let caret = CGRect(x: 980, y: 100, width: 1, height: 18)
        let frame = MarkLayout.status(size: CGSize(width: 90, height: 22), caret: caret, screen: screen)
        #expect(frame == CGRect(x: 910, y: 72, width: 90, height: 22))
    }
}
