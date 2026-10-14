import AppKit
import GWCore

struct GhostFont {
    let font: NSFont
    let baselineOffset: CGFloat
    let lineHeight: CGFloat
}

@MainActor
final class FontCache {
    private struct Key: Hashable {
        let name: String?
        let size: CGFloat
        let isBold: Bool
        let isItalic: Bool
    }

    private static let maxEntries = 64
    private var fonts: [Key: GhostFont] = [:]
    private let layoutManager = NSLayoutManager()

    func font(for style: FieldStyle, caretHeight: CGFloat) -> GhostFont {
        let key = Key(
            name: style.fontName,
            size: Self.size(for: style, caretHeight: caretHeight),
            isBold: style.isBold,
            isItalic: style.isItalic
        )
        if let cached = fonts[key] { return cached }
        let font = Self.withTraits(Self.resolve(name: key.name, size: key.size), bold: key.isBold, italic: key.isItalic)
        let ghost = GhostFont(
            font: font,
            baselineOffset: layoutManager.defaultBaselineOffset(for: font),
            lineHeight: layoutManager.defaultLineHeight(for: font)
        )
        if fonts.count >= Self.maxEntries { fonts.removeAll() }
        fonts[key] = ghost
        return ghost
    }

    static func size(for style: FieldStyle, caretHeight: CGFloat) -> CGFloat {
        let raw = style.fontSize.map { CGFloat($0) } ?? (caretHeight > 0 ? caretHeight * 0.78 : NSFont.systemFontSize)
        return (min(max(raw, 6), 200) * 2).rounded() / 2
    }

    static func withTraits(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return traits.isEmpty ? font : NSFontManager.shared.convert(font, toHaveTrait: traits)
    }

    /// AX reports the system UI font by private names such as ".SFNS-Regular", which `NSFont(name:)` maps to Times.
    static func resolve(name: String?, size: CGFloat) -> NSFont {
        guard let name else { return .systemFont(ofSize: size) }
        if name.hasPrefix(".") {
            return name.contains("Mono") ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        }
        return NSFont(name: name, size: size)
            ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
            ?? .systemFont(ofSize: size)
    }
}

struct GhostPlacement: Equatable {
    var frame: CGRect
    var textRect: CGRect
    var textClip: CGRect
    var backdrop: GhostBackdrop?
}

struct GhostBackdrop: Equatable {
    var rect: CGRect
    var color: NSColor
}

enum GhostLayout {
    static let unbounded: CGFloat = 100_000

    /// Assumes the glyphs are vertically centred in the caret rect, which holds for TextKit and CSS line boxes.
    static func baseline(caret: CGRect, font: GhostFont) -> CGFloat {
        guard caret.height > 0 else { return caret.minY + font.baselineOffset }
        return caret.midY - font.lineHeight / 2 + font.baselineOffset
    }

    static func horizontalRange(
        caret: CGRect,
        field: CGRect,
        screen: CGRect,
        direction: WritingDirection
    ) -> ClosedRange<CGFloat>? {
        let fieldKnown = field.width >= 1 && field.height >= 1
        let caretX = caret.minX
        var lower: CGFloat
        var upper: CGFloat
        if fieldKnown {
            guard field.insetBy(dx: -1, dy: -1).contains(CGPoint(x: caretX, y: caret.midY)) else { return nil }
            (lower, upper) = (field.minX, field.maxX)
        } else if direction == .leftToRight {
            (lower, upper) = (caretX, screen.maxX)
        } else {
            (lower, upper) = (screen.minX, caretX)
        }
        lower = max(lower.rounded(.down), screen.minX)
        upper = min(upper.rounded(.up), screen.maxX)
        return upper - lower >= 1 ? lower...upper : nil
    }

    /// The window spans the field's width so that typing along a line only moves the text, not the window.
    static func singleLine(
        caret: CGRect,
        field: CGRect,
        screen: CGRect,
        direction: WritingDirection,
        font: GhostFont
    ) -> GhostPlacement? {
        guard let range = horizontalRange(caret: caret, field: field, screen: screen, direction: direction)
        else { return nil }
        let lineTop = baseline(caret: caret, font: font) - font.baselineOffset
        let padding = (font.lineHeight / 2).rounded(.up)
        let top = (lineTop - padding).rounded(.down)
        let bottom = (lineTop + font.lineHeight + padding).rounded(.up)
        let frame = CGRect(x: range.lowerBound, y: top, width: range.upperBound - range.lowerBound, height: bottom - top)
        let caretX = caret.minX - frame.minX
        let textX = direction == .leftToRight ? caretX : caretX - unbounded
        let clipWidth = max(frame.width - fieldEdgeInset, 0)
        let clipX = direction == .leftToRight ? 0 : frame.width - clipWidth
        let fieldKnown = field.height >= 1
        let clipTop = fieldKnown ? min(max(field.minY - frame.minY, 0), frame.height) : 0
        let clipBottom = fieldKnown ? max(min(field.maxY - frame.minY, frame.height), clipTop) : frame.height
        return GhostPlacement(
            frame: frame,
            textRect: CGRect(x: textX, y: lineTop - top, width: unbounded, height: unbounded),
            textClip: CGRect(x: clipX, y: clipTop, width: clipWidth, height: clipBottom - clipTop)
        )
    }

    /// In a field that wraps lines the paragraph can run past the line's end, at the text inset from the field's far
    /// edge: the host shows that part on its next line, so it is left out, and the host's text is taken to fill the
    /// line up to its end. Pushed words that no longer fit on the line are left out whole, as the host would wrap them.
    static func restOfLine(
        _ snapshot: FieldSnapshot,
        range: ClosedRange<CGFloat>,
        font: NSFont,
        suggestionWidth: CGFloat
    ) -> (pushed: String, hiddenWidth: CGFloat)? {
        guard snapshot.isMidLine else { return nil }
        let rest = String(snapshot.textAfter.prefix { !$0.isNewline })
        guard rest.contains(where: { !$0.isWhitespace }) else { return nil }
        let width = textWidth(rest, font: font)
        guard holdsSeveralLines(field: snapshot.fieldFrame, caret: snapshot.caretRect) else { return (rest, width) }
        let room = roomOnLine(snapshot, range: range, font: font)
        let end = width > room ? lineEnd(of: rest, font: font, room: room) : rest.endIndex
        let onLine = String(rest[..<end])
        guard onLine.contains(where: { !$0.isWhitespace }) else { return nil }
        let pushed = String(onLine[..<lineEnd(of: onLine, font: font, room: room - suggestionWidth)])
        return (pushed, end < rest.endIndex ? room : width)
    }

    static func roomOnLine(_ snapshot: FieldSnapshot, range: ClosedRange<CGFloat>, font: NSFont) -> CGFloat {
        let margin = max(fieldEdgeInset, lineStartInset(snapshot, range: range, font: font))
        let caretX = snapshot.caretRect.minX
        return snapshot.direction == .leftToRight ? range.upperBound - margin - caretX : caretX - range.lowerBound - margin
    }

    static func runsPastLineEnd(_ text: String, snapshot: FieldSnapshot, screen: CGRect, font: NSFont) -> Bool {
        guard snapshot.isMidLine, holdsSeveralLines(field: snapshot.fieldFrame, caret: snapshot.caretRect),
              let range = horizontalRange(
                  caret: snapshot.caretRect, field: snapshot.fieldFrame, screen: screen, direction: snapshot.direction
              )
        else { return false }
        return textWidth(text, font: font) > roomOnLine(snapshot, range: range, font: font)
    }

    /// Trailing spaces hang past the end, as in the host.
    static func lineEnd(of text: String, font: NSFont, room: CGFloat) -> String.Index {
        var end = text.startIndex
        for next in lineBreaks(in: text).filter({ $0 > text.startIndex }) + [text.endIndex] {
            let piece = text[..<next]
            let visible = piece[..<(piece.lastIndex { !$0.isWhitespace }.map(piece.index(after:)) ?? piece.startIndex)]
            guard textWidth(visible, font: font) <= room else { break }
            end = next
        }
        return end
    }

    /// Keeps single-line drawing off the field's border and focus ring.
    static let fieldEdgeInset: CGFloat = 4

    /// Reaches the font's ascender and descender too, which can stick out of the caret rect.
    static func backdropRect(
        caret: CGRect,
        frame: CGRect,
        restWidth: CGFloat,
        clip: CGRect,
        direction: WritingDirection,
        font: GhostFont
    ) -> CGRect {
        let width = (restWidth + max(4, restWidth / 10)).rounded(.up)
        let baseline = baseline(caret: caret, font: font) - frame.minY
        // One point off the clip's top and bottom, where hosts draw a field's border or separator.
        let top = max(clip.minY + 1, min(caret.minY - frame.minY, (baseline - font.font.ascender).rounded(.down)))
        let bottom = min(clip.maxY - 1, max(caret.maxY - frame.minY, (baseline - font.font.descender).rounded(.up)))
        guard direction == .leftToRight else {
            let end = (caret.minX - 1 - frame.minX).rounded(.down)
            let x = max(end - width, clip.minX)
            return CGRect(x: x, y: top, width: max(0, end - x), height: bottom - top)
        }
        let x = (caret.maxX - frame.minX).rounded(.up)
        return CGRect(x: x, y: top, width: max(0, min(width, clip.maxX - x)), height: bottom - top)
    }

    static func singleLineParagraph(_ direction: WritingDirection) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        style.baseWritingDirection = direction == .leftToRight ? .leftToRight : .rightToLeft
        style.alignment = direction == .leftToRight ? .left : .right
        return style
    }

    static func multilineParagraph(
        caret: CGRect,
        range: ClosedRange<CGFloat>,
        inset: CGFloat,
        direction: WritingDirection,
        font: GhostFont
    ) -> NSParagraphStyle {
        let width = range.upperBound - range.lowerBound
        let firstIndent = direction == .leftToRight ? caret.minX - range.lowerBound : range.upperBound - caret.minX
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.baseWritingDirection = direction == .leftToRight ? .leftToRight : .rightToLeft
        // `.natural` follows the app's English localization, not the paragraph's direction, so it would left-align
        // right-to-left text.
        style.alignment = direction == .leftToRight ? .left : .right
        style.firstLineHeadIndent = min(max(firstIndent, 0), width)
        style.headIndent = inset
        style.tailIndent = -inset
        style.lineSpacing = max(caret.height - font.lineHeight, 0)
        return style
    }

    /// `text` in `paragraph`, whose first line starts at the caret. Every paragraph's first line would start there, so
    /// the paragraphs after the first start at the text margin, like the other lines.
    static func multilineString(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text, attributes: attributes.merging([.paragraphStyle: paragraph]) { $1 })
        let laterStart = NSMaxRange((text as NSString).paragraphRange(for: NSRange(location: 0, length: 0)))
        guard laterStart < string.length, let later = paragraph.mutableCopy() as? NSMutableParagraphStyle else { return string }
        later.firstLineHeadIndent = paragraph.headIndent
        string.addAttribute(.paragraphStyle, value: later, range: NSRange(location: laterStart, length: string.length - laterStart))
        return string
    }

    /// `text` moved to the next line when its first word does not fit in the `room` left on the caret's line, as the
    /// host would wrap it; laid out as is, the word would be broken across the two lines.
    static func wrappingFirstWord(_ text: String, font: NSFont, room: CGFloat) -> String {
        guard !text[..<lineEnd(of: text, font: font, room: room)].contains(where: { !$0.isWhitespace }) else { return text }
        return "\u{2028}" + text.drop(while: \.isWhitespace)
    }

    /// The field's text inset, estimated from where the caret's line starts: the caret's distance from the field's
    /// starting edge less the width of the text before it on that line. In a field that wraps lines, that text is the
    /// longest tail of the paragraph that starts at a line break opportunity and fits, which is where the host
    /// soft-wrapped it. Zero when no estimate is plausible.
    static func lineStartInset(_ snapshot: FieldSnapshot, range: ClosedRange<CGFloat>, font: NSFont) -> CGFloat {
        let before = snapshot.textBefore
        let line = String(before.lastIndex(where: \.isNewline).map { before[before.index(after: $0)...] } ?? before[...])
        let caretX = snapshot.caretRect.minX
        let room = snapshot.direction == .leftToRight ? caretX - range.lowerBound : range.upperBound - caretX
        let wraps = !line.isEmpty && holdsSeveralLines(field: snapshot.fieldFrame, caret: snapshot.caretRect)
        let tolerance = max(2, room / 50)
        var lineWidth: CGFloat?
        for start in (wraps ? lineBreaks(in: line) : [line.startIndex]).reversed() {
            let width = textWidth(line[start...], font: font)
            guard width <= room + tolerance else { break }
            lineWidth = width
        }
        guard let lineWidth else { return 0 }
        let inset = max(room - lineWidth, 0)
        return inset <= (range.upperBound - range.lowerBound) / 3 ? inset : 0
    }

    static func holdsSeveralLines(field: CGRect, caret: CGRect) -> Bool {
        field.height > caret.height * 2
    }

    static func lineBreaks(in text: String) -> [String.Index] {
        let string = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        let tokenizer = CFStringTokenizerCreate(nil, string, range, kCFStringTokenizerUnitLineBreak, nil)
        var starts: [String.Index] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            starts.append(String.Index(utf16Offset: CFStringTokenizerGetCurrentTokenRange(tokenizer).location, in: text))
        }
        return starts
    }

    static func textWidth(_ text: some StringProtocol, font: NSFont) -> CGFloat {
        NSAttributedString(string: String(text), attributes: [.font: font]).size().width
    }

    static func multiline(
        caret: CGRect,
        range: ClosedRange<CGFloat>,
        screen: CGRect,
        font: GhostFont,
        textHeight: CGFloat
    ) -> GhostPlacement? {
        let lineTop = baseline(caret: caret, font: font) - font.baselineOffset
        let padding = (font.lineHeight / 2).rounded(.up)
        let top = (lineTop - padding).rounded(.down)
        let bottom = min((lineTop + textHeight + padding).rounded(.up), screen.maxY)
        guard bottom - top >= 1 else { return nil }
        let width = range.upperBound - range.lowerBound
        return GhostPlacement(
            frame: CGRect(x: range.lowerBound, y: top, width: width, height: bottom - top),
            textRect: CGRect(x: 0, y: lineTop - top, width: width, height: unbounded),
            textClip: CGRect(x: 0, y: 0, width: width, height: bottom - top)
        )
    }
}

enum PickerLayout {
    static let caretGap: CGFloat = 4

    static func frame(size: CGSize, caret: CGRect, screen: CGRect, titleInset: CGFloat) -> CGRect {
        var x = caret.minX - titleInset
        var y = caret.maxY + caretGap
        if y + size.height > screen.maxY {
            y = caret.minY - caretGap - size.height
        }
        x = min(max(x, screen.minX), screen.maxX - size.width)
        y = min(max(y, screen.minY), screen.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
