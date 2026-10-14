import CoreGraphics
import GWCore
import Testing
@testable import Capture

@Suite struct FieldStyleTests {
    @Test func styleIsReadAgainAfterAFewTypedCharacters() {
        let menlo = FieldStyle(fontName: "Menlo-Regular", fontSize: 12)
        let cached = (caret: 10, value: menlo)
        for caret in 10...13 {
            #expect(FieldReader.reusableStyle(cached, at: caret) == menlo)
        }
        #expect(FieldReader.reusableStyle(cached, at: 14) == nil)
        #expect(FieldReader.reusableStyle(cached, at: 9) == nil)
    }

    @Test func emptyStyleIsKeptOnlyWhileTheCaretStays() {
        let cached = (caret: 0, value: FieldStyle())
        #expect(FieldReader.reusableStyle(cached, at: 0) == FieldStyle())
        #expect(FieldReader.reusableStyle(cached, at: 1) == nil)
    }
}

// Font lookups from many test threads at once stall in the test runner.
@Suite(.serialized) struct FontMatcherTests {
    @Test func closeAndClearWinnerIsChosen() {
        #expect(FontMatcher.choose([("Georgia", 0.4), (FontMatcher.systemFamily, 1.2), ("Helvetica", 1.0)]) == "Georgia")
    }

    @Test func systemFontOrNoClearWinnerKeepsTheSystemFont() {
        #expect(FontMatcher.choose([(FontMatcher.systemFamily, 0.4), ("Georgia", 1.2)]) == nil)
        #expect(FontMatcher.choose([("Georgia", 0.5), (FontMatcher.systemFamily, 0.7)]) == nil)
        #expect(FontMatcher.choose([("Georgia", 1.1), (FontMatcher.systemFamily, 2.5)]) == nil)
        #expect(FontMatcher.choose([]) == nil)
    }

    @Test func lookAlikesNeedNoLead() {
        let chosen = FontMatcher.choose([("Helvetica", 0.45), ("Arial", 0.46), (FontMatcher.systemFamily, 1.3)])
        #expect(chosen == "Helvetica")
        #expect(FontMatcher.choose([("Menlo", 0.4), ("Courier New", 0.6), ("Georgia", 9)]) == "Menlo")
    }

    private func reported(_ sample: String, family: String, size: CGFloat, origin: CGFloat = 55.37) throws -> [CGFloat] {
        let font = try #require(FontMatcher.font(family, size: size, bold: false, italic: false))
        return FontMatcher.offsets(sample, font: font).map { ($0 + origin).rounded() - origin.rounded() }
    }

    @Test(arguments: ["Georgia", "Menlo", "Times"], [55.0, 55.37, 55.5, 55.8])
    func findsTheFontFromReportedPositions(family: String, origin: CGFloat) throws {
        let sample = " for the update, I will send the"
        let positions = try reported(sample, family: family, size: 16, origin: origin)
        #expect(FontMatcher.family(sample: sample, positions: positions, size: 16, bold: false, italic: false) == family)
    }

    @Test func systemFontLayoutMatchesNothing() throws {
        let sample = "Thanks for the update, I will send the"
        let positions = try reported(sample, family: FontMatcher.systemFamily, size: 16)
        #expect(FontMatcher.family(sample: sample, positions: positions, size: 16, bold: false, italic: false) == nil)
    }

    @Test func shortSampleIsSkipped() throws {
        let positions = try reported("Thanks", family: "Georgia", size: 16)
        #expect(FontMatcher.family(sample: "Thanks", positions: positions, size: 16, bold: false, italic: false) == nil)
    }
}
