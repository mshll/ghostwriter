import CoreFoundation
import Foundation
import Testing
@testable import Capture

@Suite struct TextExtractorTests {
    @Test func selectionMovesPastParagraphBreaksMissingFromItsOffsets() {
        let value = "first line\nsecond line\nmost of o" as NSString
        let indexed = "first linesecond linemost of o" as NSString
        let range = TextExtractor.valueRange(of: CFRange(location: 30, length: 0), indexed: indexed, in: value)
        #expect(range?.location == 32)
        #expect(range?.length == 0)
    }

    @Test func selectionAcrossAParagraphBreakTakesTheBreak() {
        let range = TextExtractor.valueRange(of: CFRange(location: 1, length: 2), indexed: "abc", in: "ab\ncd")
        #expect(range?.location == 1)
        #expect(range?.length == 3)
    }

    @Test func caretAtAParagraphBreakStaysBeforeIt() {
        let range = TextExtractor.valueRange(of: CFRange(location: 2, length: 0), indexed: "ab", in: "ab\ncd")
        #expect(range?.location == 2)
    }

    @Test func lineBreaksInBothTextsKeepTheSelection() {
        let range = TextExtractor.valueRange(of: CFRange(location: 3, length: 0), indexed: "a\nb", in: "a\nb")
        #expect(range?.location == 3)
    }

    @Test func otherDifferencesGiveNoRange() {
        #expect(TextExtractor.valueRange(of: CFRange(location: 3, length: 0), indexed: "abd", in: "abc") == nil)
        #expect(TextExtractor.valueRange(of: CFRange(location: 3, length: 0), indexed: "ab", in: "abc") == nil)
    }
}
