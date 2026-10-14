import AppKit
import GWCore
import Testing
@testable import Overlay

@MainActor @Suite struct GhostOverlayPlacementTests {
    private func snapshot(caret: CGRect, field: CGRect) -> FieldSnapshot {
        FieldSnapshot(
            id: FieldID(pid: 1, elementHash: 1),
            app: AppIdentity(bundleID: "test", name: "Test", pid: 1),
            textBefore: "Hello",
            textAfter: "",
            caretRect: caret,
            fieldFrame: field
        )
    }

    @Test func zeroCaretIsNotShown() {
        let overlay = GhostOverlay()
        #expect(!overlay.show(" world", for: snapshot(caret: .zero, field: CGRect(x: 100, y: 100, width: 400, height: 40))))
        #expect(!overlay.isVisible)
    }

    @Test func caretOutsideTheFieldIsNotShown() {
        let overlay = GhostOverlay()
        let field = CGRect(x: 100, y: 100, width: 400, height: 40)
        #expect(!overlay.show(" world", for: snapshot(caret: CGRect(x: 100, y: 600, width: 1, height: 18), field: field)))
        #expect(!overlay.isVisible)
    }

    @Test func pickerNeedsRowsAndACaret() {
        let overlay = GhostOverlay()
        let caret = CGRect(x: 100, y: 100, width: 1, height: 18)
        #expect(!overlay.showPicker([], near: caret) { _ in })
        #expect(!overlay.showPicker([PickerItem(title: "a")], near: .zero) { _ in })
        #expect(!overlay.isPickerVisible)
    }

    @Test func multilineGhostMidLineCoversTheRestOfTheCaretLine() throws {
        let field = CGRect(x: 100, y: 100, width: 300, height: 200)
        let caret = CGRect(x: 380, y: 140, width: 1, height: 16)
        var midLine = snapshot(caret: caret, field: field)
        midLine.textAfter = "."
        let draft = " and I will send the full report with the numbers to the whole team on Friday morning."
        let overlay = GhostOverlay()
        #expect(overlay.show(draft, for: midLine, multiline: true))
        defer { overlay.hide() }
        let view = overlay.ghostView
        #expect(view.bounds.height > caret.height * 3)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        func covered(from x: CGFloat) -> Bool {
            let columns = Int((x - field.minX) * scale)..<Int((x + 6 - field.minX) * scale)
            return (0..<rep.pixelsHigh).contains { y in
                columns.allSatisfy { (rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.99 }
            }
        }
        #expect(covered(from: caret.maxX + 1))
        #expect(!covered(from: caret.minX - 20))
    }

    @Test func pushedTextWithoutAFieldColorIsFullStrength() {
        let dark = GhostOverlay.hostTextColor(FieldStyle(), background: NSColor(white: 0.12, alpha: 1))
        let light = GhostOverlay.hostTextColor(FieldStyle(), background: NSColor(white: 0.95, alpha: 1))
        #expect(dark.whiteComponent == 1 && dark.alphaComponent == 1)
        #expect(light.whiteComponent == 0 && light.alphaComponent == 1)
    }

    @Test(arguments: [0.3, 0.7])
    func opacityAppliesWithAndWithoutAFieldColor(opacity: Double) {
        var appearance = OverlayAppearance()
        appearance.opacity = opacity
        let red = FieldStyle(textColor: RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.8))
        #expect(abs(GhostOverlay.ghostColor(red, appearance: appearance).alphaComponent - 0.8 * opacity) < 0.001)
        #expect(abs(GhostOverlay.ghostColor(FieldStyle(), appearance: appearance).alphaComponent - opacity) < 0.001)
    }
}

@Suite struct BackgroundSamplerTests {
    @Test func dominantColorIgnoresMinorityTextPixels() throws {
        var pixels: [UInt8] = []
        for index in 0..<100 {
            pixels += index < 70 ? [30, 30, 30, 255] : [235, 235, 235, 255]
        }
        let color = try #require(BackgroundSampler.dominantColor(rgba: pixels))
        #expect(abs(color.red - 30.0 / 255) < 0.001 && abs(color.blue - 30.0 / 255) < 0.001)
    }

    @Test func dominantColorOfNothingIsNil() {
        #expect(BackgroundSampler.dominantColor(rgba: [UInt8]()) == nil)
    }

    @Test @MainActor func restOfLineOnlyMidLine() {
        var snapshot = FieldSnapshot(
            id: FieldID(pid: 1, elementHash: 1),
            app: AppIdentity(bundleID: "test", name: "Test", pid: 1),
            textBefore: "The meeting is",
            textAfter: "",
            caretRect: CGRect(x: 110, y: 45, width: 1, height: 14),
            fieldFrame: CGRect(x: 100, y: 40, width: 300, height: 24)
        )
        let rest = { GhostLayout.restOfLine(snapshot, range: 100...400, font: .systemFont(ofSize: 12), suggestionWidth: 30)?.pushed }
        snapshot.textAfter = " Tuesday at noon.\nNext line"
        #expect(rest() == " Tuesday at noon.")
        snapshot.textAfter = "\nNext line"
        #expect(rest() == nil)
        snapshot.textAfter = "   "
        #expect(rest() == nil)
        snapshot.direction = .rightToLeft
        snapshot.textAfter = " يوم الثلاثاء\nسطر"
        #expect(rest() == " يوم الثلاثاء")
    }

    private let smallFont = GhostFont(font: .systemFont(ofSize: 10), baselineOffset: 9, lineHeight: 12)

    @Test func backdropCoversTheRestOfTheLineOnly() {
        let caret = CGRect(x: 110, y: 52, width: 1, height: 14)
        let frame = CGRect(x: 100, y: 40, width: 300, height: 40)
        let clip = CGRect(x: 0, y: 0, width: 296, height: 40)
        let backdrop = { (restWidth: CGFloat) in
            GhostLayout.backdropRect(
                caret: caret, frame: frame, restWidth: restWidth, clip: clip, direction: .leftToRight, font: self.smallFont
            )
        }
        #expect(backdrop(100).minX == 11 && backdrop(100).width == 110)
        #expect(backdrop(1000).minX == 11 && backdrop(1000).width == 285)
    }

    @Test func rightToLeftBackdropCoversTheRestLeftOfTheCaret() {
        let caret = CGRect(x: 300, y: 52, width: 1, height: 14)
        let frame = CGRect(x: 100, y: 40, width: 300, height: 40)
        let clip = CGRect(x: 4, y: 0, width: 296, height: 40)
        let backdrop = { (restWidth: CGFloat) in
            GhostLayout.backdropRect(
                caret: caret, frame: frame, restWidth: restWidth, clip: clip, direction: .rightToLeft, font: self.smallFont
            )
        }
        #expect(backdrop(100).minX == 89 && backdrop(100).width == 110)
        #expect(backdrop(1000).minX == 4 && backdrop(1000).width == 195)
    }

    @Test func backdropCoversDescendersBelowTheCaret() {
        let font = GhostFont(font: .systemFont(ofSize: 20), baselineOffset: 19, lineHeight: 24)
        let caret = CGRect(x: 110, y: 52, width: 1, height: 18)
        let frame = CGRect(x: 100, y: 30, width: 300, height: 60)
        let clip = CGRect(x: 0, y: 0, width: 296, height: 60)
        let rect = GhostLayout.backdropRect(caret: caret, frame: frame, restWidth: 50, clip: clip, direction: .leftToRight, font: font)
        let baseline = GhostLayout.baseline(caret: caret, font: font) - frame.minY
        #expect(rect.minY <= caret.minY - frame.minY && rect.minY <= baseline - font.font.ascender)
        #expect(rect.maxY >= caret.maxY - frame.minY && rect.maxY >= baseline - font.font.descender)
        #expect(rect.maxY > caret.maxY - frame.minY)
    }
}

@MainActor @Suite struct GhostLayoutTests {
    private let font = GhostFont(font: .systemFont(ofSize: 13), baselineOffset: 12, lineHeight: 16)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let field = CGRect(x: 100, y: 40, width: 300, height: 30)
    private let tallField = CGRect(x: 100, y: 40, width: 300, height: 200)

    @Test func fieldWeightAndSlantApply() {
        let style = FieldStyle(fontSize: 16, isBold: true, isItalic: true)
        let georgia = FontCache().font(for: FieldStyle(fontName: "Georgia", fontSize: 16, isBold: true), caretHeight: 18).font
        let system = FontCache().font(for: style, caretHeight: 18).font
        #expect(georgia.familyName == "Georgia" && NSFontManager.shared.traits(of: georgia).contains(.boldFontMask))
        #expect(NSFontManager.shared.traits(of: system).contains([.boldFontMask, .italicFontMask]))
    }

    @Test func endOfLineTextStopsShortOfTheFieldEdge() throws {
        let caret = CGRect(x: 380, y: 47, width: 1, height: 16)
        let ltr = try #require(GhostLayout.singleLine(caret: caret, field: field, screen: screen, direction: .leftToRight, font: font))
        #expect(ltr.frame.minX == 100 && ltr.frame.width == 300)
        #expect(ltr.textClip.minX == 0 && ltr.textClip.maxX == 296)
        let rtl = try #require(GhostLayout.singleLine(caret: caret, field: field, screen: screen, direction: .rightToLeft, font: font))
        #expect(rtl.textClip.minX == 4 && rtl.textClip.maxX == 300)
    }

    @Test func drawingStaysInsideTheField() throws {
        let tight = CGRect(x: 100, y: 47, width: 300, height: 16)
        let caret = CGRect(x: 150, y: 47, width: 1, height: 16)
        let placement = try #require(GhostLayout.singleLine(caret: caret, field: tight, screen: screen, direction: .leftToRight, font: font))
        #expect(placement.textClip.minY == tight.minY - placement.frame.minY)
        #expect(placement.textClip.maxY == tight.maxY - placement.frame.minY)
        let big = GhostFont(font: .systemFont(ofSize: 20), baselineOffset: 19, lineHeight: 24)
        let backdrop = GhostLayout.backdropRect(
            caret: caret, frame: placement.frame, restWidth: 50, clip: placement.textClip, direction: .leftToRight, font: big
        )
        #expect(backdrop.minY == placement.textClip.minY + 1 && backdrop.maxY == placement.textClip.maxY - 1)
    }

    private func snapshot(
        before: String,
        lineTail: String,
        field: CGRect,
        direction: WritingDirection = .leftToRight
    ) -> FieldSnapshot {
        let width = GhostLayout.textWidth(lineTail, font: font.font)
        let caretX = direction == .leftToRight ? field.minX + 5 + width : field.maxX - 5 - width
        return FieldSnapshot(
            id: FieldID(pid: 1, elementHash: 1),
            app: AppIdentity(bundleID: "test", name: "Test", pid: 1),
            textBefore: before,
            textAfter: "",
            caretRect: CGRect(x: caretX, y: field.minY + 40, width: 1, height: 16),
            fieldFrame: field,
            direction: direction
        )
    }

    private func inset(_ snapshot: FieldSnapshot) -> CGFloat {
        GhostLayout.lineStartInset(snapshot, range: snapshot.fieldFrame.minX...snapshot.fieldFrame.maxX, font: font.font)
    }

    @Test func insetFromAnUnwrappedLine() {
        let line = snapshot(before: "First paragraph.\nHello there", lineTail: "Hello there", field: tallField)
        #expect(abs(inset(line) - 5) < 0.01)
        let empty = snapshot(before: "First paragraph.\n", lineTail: "", field: tallField)
        #expect(abs(inset(empty) - 5) < 0.01)
    }

    @Test func insetFromASoftWrappedLine() {
        let paragraph = "The meeting moved to Tuesday because the venue was booked for the whole week, so "
        let tail = "please update your calendars and "
        #expect(GhostLayout.textWidth(paragraph + tail, font: font.font) > tallField.width)
        #expect(abs(inset(snapshot(before: paragraph + tail, lineTail: tail, field: tallField)) - 5) < 0.01)
        let arabic = "انتقل الاجتماع إلى يوم الثلاثاء لأن القاعة كانت محجوزة طوال الأسبوع كله، لذلك "
        let arabicTail = "يرجى تحديث التقويم الخاص بكم "
        #expect(GhostLayout.textWidth(arabic + arabicTail, font: font.font) > tallField.width)
        let rtl = snapshot(before: arabic + arabicTail, lineTail: arabicTail, field: tallField, direction: .rightToLeft)
        #expect(abs(inset(rtl) - 5) < 0.01)
    }

    @Test(arguments: [WritingDirection.leftToRight, .rightToLeft])
    func softWrappedRestIsCutAtTheLineEnd(direction: WritingDirection) throws {
        let (before, onLine, after) = direction == .leftToRight
            ? ("Hello", " world, this sentence ", "keeps going past the end of the line\nNext")
            : ("مرحبا", " بالعالم، هذه الجملة ", "تستمر إلى ما بعد نهاية السطر\nالتالي")
        let room = GhostLayout.textWidth(onLine.dropLast(), font: font.font) + 2
        let width = 5 + GhostLayout.textWidth(before, font: font.font) + room + 5
        var line = snapshot(before: before, lineTail: before, field: CGRect(x: 100, y: 40, width: width, height: 200), direction: direction)
        line.textAfter = onLine + after
        let range = line.fieldFrame.minX...line.fieldFrame.maxX
        let rest = try #require(GhostLayout.restOfLine(line, range: range, font: font.font, suggestionWidth: 0))
        #expect(rest.pushed == onLine)
        #expect(abs(rest.hiddenWidth - room) < 0.01)
        let lastWord = String(onLine.split(separator: " ").last ?? "")
        let pushed = try #require(GhostLayout.restOfLine(line, range: range, font: font.font, suggestionWidth: 20))
        #expect(onLine.hasPrefix(pushed.pushed) && !pushed.pushed.contains(lastWord))
        #expect(abs(pushed.hiddenWidth - room) < 0.01)
        // A single-line field scrolls instead of wrapping: the whole rest is pushed aside.
        line.fieldFrame.size.height = 30
        let wholeRest = String(line.textAfter.prefix { !$0.isNewline })
        #expect(GhostLayout.restOfLine(line, range: range, font: font.font, suggestionWidth: 20)?.pushed == wholeRest)
    }

    @Test func midLineSuggestionPastTheLineEndWraps() {
        let suggestion = ", October 18 at noon"
        let room = GhostLayout.textWidth(suggestion, font: font.font) - 10
        let width = 5 + GhostLayout.textWidth("Friday", font: font.font) + room + 5
        var line = snapshot(before: "Friday", lineTail: "Friday", field: CGRect(x: 100, y: 40, width: width, height: 200))
        line.textAfter = "."
        #expect(GhostLayout.runsPastLineEnd(suggestion, snapshot: line, screen: screen, font: font.font))
        #expect(!GhostLayout.runsPastLineEnd(", October", snapshot: line, screen: screen, font: font.font))
        var lineEnd = line
        lineEnd.textAfter = "\nThanks"
        #expect(!GhostLayout.runsPastLineEnd(suggestion, snapshot: lineEnd, screen: screen, font: font.font))
        var singleLineField = line
        singleLineField.fieldFrame.size.height = 30
        singleLineField.caretRect.origin.y = singleLineField.fieldFrame.minY + 7
        #expect(!GhostLayout.runsPastLineEnd(suggestion, snapshot: singleLineField, screen: screen, font: font.font))
    }

    @Test func caretAtASoftWrapPushesNothingAside() {
        let width = 5 + GhostLayout.textWidth("Hello", font: font.font) + 5
        var line = snapshot(before: "Hello", lineTail: "Hello", field: CGRect(x: 100, y: 40, width: width, height: 200))
        line.textAfter = " world"
        let range = line.fieldFrame.minX...line.fieldFrame.maxX
        #expect(GhostLayout.restOfLine(line, range: range, font: font.font, suggestionWidth: 0) == nil)
    }

    @Test(arguments: [WritingDirection.leftToRight, .rightToLeft])
    func multilineGhostStartsAtTheCaret(direction: WritingDirection) throws {
        let range: ClosedRange<CGFloat> = 100...500
        let caret = CGRect(x: direction == .leftToRight ? 200 : 400, y: 60, width: 1, height: 16)
        let style = GhostLayout.multilineParagraph(caret: caret, range: range, inset: 5, direction: direction, font: font)
        let string = NSAttributedString(
            string: direction == .leftToRight ? "next week" : "يوم الجمعة",
            attributes: [.font: font.font, .foregroundColor: NSColor.black, .paragraphStyle: style]
        )
        let placement = try #require(GhostLayout.multiline(caret: caret, range: range, screen: screen, font: font, textHeight: 20))
        let view = GhostTextView(frame: CGRect(origin: .zero, size: placement.frame.size))
        view.update(text: string, in: placement.textRect, clip: placement.textClip, backdrop: nil)
        let ink = try #require(inkExtent(view))
        if direction == .leftToRight {
            #expect(abs(ink.lowerBound - 100) < 2)
        } else {
            #expect(abs(ink.upperBound - 300) < 2)
        }
    }

    @Test func laterParagraphsOfAMultilineGhostStartAtTheTextMargin() {
        let caret = CGRect(x: 400, y: 60, width: 1, height: 16)
        let style = GhostLayout.multilineParagraph(caret: caret, range: 100...500, inset: 5, direction: .leftToRight, font: font)
        let text = "\u{2028}next week.\nThanks"
        let string = GhostLayout.multilineString(text, attributes: [.font: font.font], paragraph: style)
        func indent(at offset: Int) -> CGFloat? {
            (string.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent
        }
        #expect(indent(at: 0) == 300)
        #expect(indent(at: (text as NSString).range(of: "next").location) == 300)
        #expect(indent(at: (text as NSString).range(of: "Thanks").location) == 5)
    }

    @Test func firstWordThatDoesNotFitStartsOnTheNextLine() {
        #expect(GhostLayout.wrappingFirstWord(" Thursday morning", font: font.font, room: 10) == "\u{2028}Thursday morning")
        #expect(GhostLayout.wrappingFirstWord("بعد غد.", font: font.font, room: 5) == "\u{2028}بعد غد.")
        #expect(GhostLayout.wrappingFirstWord(" Thursday morning", font: font.font, room: 200) == " Thursday morning")
        let thursday = GhostLayout.textWidth(" Thursday", font: font.font)
        #expect(GhostLayout.wrappingFirstWord(" Thursday morning", font: font.font, room: thursday + 1) == " Thursday morning")
    }

    private func inkExtent(_ view: NSView) -> ClosedRange<CGFloat>? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let inked = (0..<rep.pixelsWide).filter { x in
            (0..<rep.pixelsHigh).contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.2 }
        }
        guard let first = inked.first, let last = inked.last else { return nil }
        return CGFloat(first) / scale...CGFloat(last + 1) / scale
    }

    @Test func singleLineFieldThatScrolledHasNoInset() {
        let text = "The meeting moved to Tuesday because the venue was booked for the whole week"
        let scrolled = snapshot(before: text, lineTail: "the whole week", field: field)
        #expect(inset(scrolled) == 0)
    }
}
