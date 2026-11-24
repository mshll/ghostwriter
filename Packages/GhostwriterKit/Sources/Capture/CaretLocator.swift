import ApplicationServices
import CoreGraphics
import Foundation
import GWCore

final class CaretCalibration {
    /// Whether `AXBoundsForRange` of a zero-length range sits one line above the caret (TextEdit does this).
    var collapsedRangeIsLineAbove: Bool?
}

enum CaretLocator {
    struct Caret {
        var rect: CGRect
        var source: ReadDiagnostics.CaretSource
    }

    /// The first rect that looks like a real line box wins. One outside the field means the caret is scrolled out of view:
    /// it is returned as is (callers compare it with the field frame) because every other source would be out of view too.
    static func caret(
        _ element: AXElement, text: ExtractedText, frame: CGRect?, style: FieldStyle, direction: WritingDirection,
        calibration: CaretCalibration
    ) throws(AXFailure) -> Caret {
        let before = text.characterBeforeCaret
        let after = text.after.first
        let rightToLeft = (before.flatMap(FieldClassifier.direction(of:)) ?? direction) == .rightToLeft
        var caretMarker: AXTextMarker?
        switch text.location {
        case .range(let selection):
            let caret = selection.location + selection.length
            let previous = try characterBox(element, before, at: caret - (before?.utf16.count ?? 0), frame: frame)
            let next = previous == nil || before?.isWhitespace == true
                ? try characterBox(element, after, at: caret, frame: frame) : nil
            if let previous, let before {
                if let next, let after, !onSameLine(previous, next),
                   let line = try caretLine(
                       element, at: caret, text: text, frame: frame, style: style, rightToLeft: rightToLeft,
                       calibration: calibration
                   ),
                   isOnNextLine(line, previous: previous, next: next) {
                    return Caret(rect: edge(of: next, after, trailing: false, direction: direction), source: .nextCharacter)
                }
                return Caret(rect: edge(of: previous, before, trailing: true, direction: direction), source: .previousCharacter)
            }
            if let next, let after {
                return Caret(rect: edge(of: next, after, trailing: false, direction: direction), source: .nextCharacter)
            }
            caretMarker = try selectionEndMarker(element)
            if let caret = try collapsedCaret(
                element, at: caret, marker: caretMarker, text: text, frame: frame, style: style, rightToLeft: rightToLeft,
                calibration: calibration
            ) { return caret }
        case .markers(_, let selectionEnd):
            caretMarker = selectionEnd
            if let caret = try collapsedMarkerCaret(element, at: selectionEnd, frame: frame, style: style, rightToLeft: rightToLeft) {
                return caret
            }
        }
        if let caretMarker, let caret = try previousMarkerCaret(element, at: caretMarker, frame: frame, rightToLeft: rightToLeft) {
            return caret
        }
        return estimate(frame, style: style, rightToLeft: direction == .rightToLeft)
    }

    /// The trailing edge of the last character before the spaces that end the text before the caret, on the caret's line.
    static func visibleTextEnd(
        _ element: AXElement, text: ExtractedText, caret: CGRect, frame: CGRect?, direction: WritingDirection
    ) throws(AXFailure) -> CGFloat? {
        guard case .range(let selection) = text.location, text.selected.isEmpty else { return nil }
        let spaces = text.before.reversed().prefix { $0.isWhitespace && !$0.isNewline }
        guard !spaces.isEmpty, let character = text.before.dropLast(spaces.count).last, !character.isNewline else {
            return nil
        }
        let location = selection.location - spaces.reduce(0) { $0 + $1.utf16.count } - character.utf16.count
        guard let box = try characterBox(element, character, at: location, frame: frame), onSameLine(box, caret) else {
            return nil
        }
        return edge(of: box, character, trailing: true, direction: direction).minX
    }

    private static func characterBox(
        _ element: AXElement, _ character: Character?, at location: Int, frame: CGRect?
    ) throws(AXFailure) -> CGRect? {
        guard let character, !character.isNewline, location >= 0,
              let rect = try bounds(element, CFRange(location: location, length: character.utf16.count)),
              isSane(rect, in: frame) else { return nil }
        return rect
    }

    private static func edge(of box: CGRect, _ character: Character, trailing: Bool, direction: WritingDirection) -> CGRect {
        let rightToLeft = (FieldClassifier.direction(of: character) ?? direction) == .rightToLeft
        return line(at: rightToLeft == trailing ? box.minX : box.maxX, box)
    }

    /// At a soft wrap the characters on either side of the caret sit on different lines.
    static func onSameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midY - b.midY) < min(a.height, b.height) / 2
    }

    static func isOnNextLine(_ caretLine: CGRect, previous: CGRect, next: CGRect) -> Bool {
        onSameLine(caretLine, next) && !onSameLine(caretLine, previous)
    }

    /// The line the app draws the caret on. At a soft wrap the same offset is the end of one line or the start of the
    /// next, by the caret's affinity. Chromium answers a collapsed marker at the next line's start whatever the affinity;
    /// its line range follows it.
    private static func caretLine(
        _ element: AXElement, at caret: Int, text: ExtractedText, frame: CGRect?, style: FieldStyle, rightToLeft: Bool,
        calibration: CaretCalibration
    ) throws(AXFailure) -> CGRect? {
        let marker = try selectionEndMarker(element)
        if let marker,
           let range = AXDecode.markerRange(try element.parameterized(
               kAXLineTextMarkerRangeForTextMarkerParameterizedAttribute, marker
           )),
           let rect = AXDecode.rect(try element.parameterized(kAXBoundsForTextMarkerRangeParameterizedAttribute, range)),
           rect.minY.isFinite, rect.height > 0 {
            return rect
        }
        return try collapsedCaret(
            element, at: caret, marker: marker, text: text, frame: frame, style: style, rightToLeft: rightToLeft,
            calibration: calibration
        )?.rect
    }

    /// Where the app itself puts a caret with nothing selected: the collapsed text marker, else the zero-length range.
    private static func collapsedCaret(
        _ element: AXElement, at caret: Int, marker: AXTextMarker?, text: ExtractedText, frame: CGRect?, style: FieldStyle,
        rightToLeft: Bool, calibration: CaretCalibration
    ) throws(AXFailure) -> Caret? {
        if let marker,
           let caret = try collapsedMarkerCaret(element, at: marker, frame: frame, style: style, rightToLeft: rightToLeft) {
            return caret
        }
        guard var rect = try bounds(element, CFRange(location: caret, length: 0)) else { return nil }
        if try collapsedRangeIsLineAbove(element, text: text, caret: caret, frame: frame, calibration: calibration) {
            rect.origin.y += rect.height
        }
        return isSane(rect, in: frame) ? Caret(rect: line(at: rect.minX, rect), source: .collapsedRange) : nil
    }

    /// Learned once per field from a character's own box: on an empty line the neighbours are line breaks, whose boxes
    /// sit on different lines in different apps. Text of line breaks only has no such box, so the first line's
    /// collapsed range is held against the field's top edge.
    private static func collapsedRangeIsLineAbove(
        _ element: AXElement, text: ExtractedText, caret: Int, frame: CGRect?, calibration: CaretCalibration
    ) throws(AXFailure) -> Bool {
        if let known = calibration.collapsedRangeIsLineAbove { return known }
        guard let anchor = anchor(before: text.before + text.selected, after: text.after, caret: caret) else {
            guard let frame, let first = try bounds(element, CFRange(location: 0, length: 0)) else { return false }
            return isLineAbove(first, CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 0))
        }
        guard let box = try bounds(element, anchor), isSane(box, in: frame),
              let collapsed = try bounds(element, CFRange(location: anchor.location, length: 0))
        else { return false }
        let lineAbove = isLineAbove(collapsed, box)
        calibration.collapsedRangeIsLineAbove = lineAbove
        return lineAbove
    }

    /// The character nearest the caret that is not a line break, as a UTF-16 range.
    static func anchor(before: String, after: String, caret: Int) -> CFRange? {
        if let index = before.lastIndex(where: { !$0.isNewline }) {
            return CFRange(location: caret - before[index...].utf16.count, length: before[index].utf16.count)
        }
        if let index = after.firstIndex(where: { !$0.isNewline }) {
            return CFRange(location: caret + after[..<index].utf16.count, length: after[index].utf16.count)
        }
        return nil
    }

    static func isLineAbove(_ collapsed: CGRect, _ character: CGRect) -> Bool {
        collapsed.height > 0 && abs(collapsed.maxY - character.minY) < 1
            && abs(collapsed.minY - character.minY) >= 1
    }

    static func style(_ element: AXElement, text: ExtractedText) throws(AXFailure) -> FieldStyle {
        let value: CFTypeRef?
        switch text.location {
        case .range(let selection):
            let caret = selection.location + selection.length
            let index = caret > 0 ? caret - 1 : 0
            guard index < text.totalLength, let parameter = AXDecode.rangeValue(CFRange(location: index, length: 1)) else {
                return FieldStyle()
            }
            value = try element.parameterized(kAXAttributedStringForRangeParameterizedAttribute, parameter)
        case .markers(_, let selectionEnd):
            guard let previous = AXDecode.marker(try element.parameterized(
                kAXPreviousTextMarkerForTextMarkerParameterizedAttribute, selectionEnd
            )) else { return FieldStyle() }
            let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, previous, selectionEnd)
            value = try element.parameterized(kAXAttributedStringForTextMarkerRangeParameterizedAttribute, range)
        }
        guard let attributed = value as? NSAttributedString, attributed.length > 0 else { return FieldStyle() }
        let attributes = attributed.attributes(at: attributed.length - 1, effectiveRange: nil)
        let font = attributes[NSAttributedString.Key(AXName.fontText)] as? [String: Any]
        return FieldStyle(
            fontName: font?[AXName.fontName] as? String,
            fontSize: (font?[AXName.fontSize] as? NSNumber)?.doubleValue,
            textColor: AXDecode.color(attributes[NSAttributedString.Key(AXName.foregroundColorText)].map { $0 as AnyObject })
                .flatMap(rgba),
            isBold: (font?[AXName.fontBold] as? NSNumber)?.boolValue ?? false,
            isItalic: (font?[AXName.fontItalic] as? NSNumber)?.boolValue ?? false
        )
    }

    private static func collapsedMarkerCaret(
        _ element: AXElement, at marker: AXTextMarker, frame: CGRect?, style: FieldStyle, rightToLeft: Bool
    ) throws(AXFailure) -> Caret? {
        guard let rect = try markerBounds(element, from: marker, to: marker) else { return nil }
        if isSane(rect, in: frame) {
            return Caret(rect: line(at: rect.minX, rect), source: .textMarker)
        }
        return emptyLineCaret(rect, in: frame, style: style, rightToLeft: rightToLeft).map { Caret(rect: $0, source: .textMarker) }
    }

    private static func previousMarkerCaret(
        _ element: AXElement, at marker: AXTextMarker, frame: CGRect?, rightToLeft: Bool
    ) throws(AXFailure) -> Caret? {
        guard let previous = AXDecode.marker(try element.parameterized(
                  kAXPreviousTextMarkerForTextMarkerParameterizedAttribute, marker
              )),
              let rect = try markerBounds(element, from: previous, to: marker), isSane(rect, in: frame)
        else { return nil }
        return Caret(rect: line(at: rightToLeft ? rect.minX : rect.maxX, rect), source: .textMarker)
    }

    private static func selectionEndMarker(_ element: AXElement) throws(AXFailure) -> AXTextMarker? {
        AXDecode.markerRange(try element.value(kAXSelectedTextMarkerRangeAttribute)).map(AXTextMarkerRangeCopyEndMarker)
    }

    /// Chromium answers a collapsed range on an empty line with that line's box, which spans the field's width. On an
    /// empty line between two `<br>` in a contenteditable it answers with the whole editable box, which is no line.
    static func emptyLineCaret(_ rect: CGRect, in frame: CGRect?, style: FieldStyle, rightToLeft: Bool) -> CGRect? {
        guard let frame, rect.minX.isFinite, rect.minY.isFinite, rect.height > 0, rect.height <= 2 * lineHeight(style),
              rect.width > FieldReader.maxCaretWidth, frame.insetBy(dx: -1, dy: -1).contains(rect)
        else { return nil }
        return line(at: rightToLeft ? rect.maxX : rect.minX, rect)
    }

    private static func estimate(_ frame: CGRect?, style: FieldStyle, rightToLeft: Bool) -> Caret {
        guard let frame else { return Caret(rect: .zero, source: .none) }
        let lineHeight = min(frame.height, lineHeight(style))
        let y = frame.height <= lineHeight * 2 ? frame.midY - lineHeight / 2 : frame.minY + 4
        let x = rightToLeft ? frame.maxX - 5 : frame.minX + 4
        return Caret(rect: CGRect(x: x, y: y, width: 1, height: lineHeight), source: .estimate)
    }

    private static func lineHeight(_ style: FieldStyle) -> CGFloat {
        max(12, (style.fontSize ?? 13) * 1.25)
    }

    private static func line(at x: CGFloat, _ rect: CGRect) -> CGRect {
        CGRect(x: x, y: rect.minY, width: 1, height: rect.height)
    }

    /// A real line box: finite, positive height, not wider than a few glyphs, not at the origin (a common garbage answer).
    /// Near the field it must be on a display; away from the field it is a caret scrolled out of view.
    private static func isSane(_ rect: CGRect, in frame: CGRect?) -> Bool {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.origin != .zero, rect.height > 0, rect.height < 400,
              rect.width >= 0, rect.width <= FieldReader.maxCaretWidth else { return false }
        let anchor = CGPoint(x: rect.midX, y: rect.midY)
        if let frame, !frame.insetBy(dx: -20, dy: -20).contains(anchor) { return true }
        return isOnSomeDisplay(anchor)
    }

    private static func isOnSomeDisplay(_ point: CGPoint) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return true }
        return displays.prefix(Int(count)).contains { CGDisplayBounds($0).contains(point) }
    }

    private static func bounds(_ element: AXElement, _ range: CFRange) throws(AXFailure) -> CGRect? {
        guard let parameter = AXDecode.rangeValue(range) else { return nil }
        return AXDecode.rect(try element.parameterized(kAXBoundsForRangeParameterizedAttribute, parameter))
    }

    private static func markerBounds(
        _ element: AXElement, from start: AXTextMarker, to end: AXTextMarker
    ) throws(AXFailure) -> CGRect? {
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
        return AXDecode.rect(try element.parameterized(kAXBoundsForTextMarkerRangeParameterizedAttribute, range))
    }

    /// RGB components are taken as sRGB without conversion: Chromium tags CSS (sRGB) colors as Generic RGB.
    private static func rgba(_ color: CGColor) -> RGBAColor? {
        var rgb = color
        if color.colorSpace?.model != .rgb {
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                  let converted = color.converted(to: sRGB, intent: .defaultIntent, options: nil) else { return nil }
            rgb = converted
        }
        guard let components = rgb.components, components.count >= 3 else { return nil }
        return RGBAColor(
            red: components[0], green: components[1], blue: components[2],
            alpha: components.count > 3 ? components[3] : 1
        )
    }
}
