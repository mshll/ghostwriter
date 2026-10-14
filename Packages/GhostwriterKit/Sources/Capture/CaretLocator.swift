import ApplicationServices
import CoreGraphics
import Foundation
import GWCore

final class CaretCalibration {
    /// Bundle ID -> whether `AXBoundsForRange` of a zero-length range sits one line above the caret (TextEdit does this).
    var collapsedRangeIsLineAbove: [String: Bool] = [:]
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
        bundleID: String, calibration: CaretCalibration
    ) throws(AXFailure) -> Caret {
        let before = text.characterBeforeCaret
        let after = text.after.first
        var caretMarker: AXTextMarker?
        switch text.location {
        case .range(let selection):
            let caret = selection.location + selection.length
            if let before, !before.isNewline, caret >= before.utf16.count,
               let rect = try bounds(element, CFRange(location: caret - before.utf16.count, length: before.utf16.count)),
               isSane(rect, in: frame) {
                if calibration.collapsedRangeIsLineAbove[bundleID] == nil,
                   let collapsed = try bounds(element, CFRange(location: caret, length: 0)) {
                    calibration.collapsedRangeIsLineAbove[bundleID] = isLineAbove(collapsed, rect)
                }
                let rightToLeft = (FieldClassifier.direction(of: before) ?? direction) == .rightToLeft
                return Caret(rect: line(at: rightToLeft ? rect.minX : rect.maxX, rect), source: .previousCharacter)
            }
            if let after, !after.isNewline,
               let rect = try bounds(element, CFRange(location: caret, length: after.utf16.count)), isSane(rect, in: frame) {
                let rightToLeft = (FieldClassifier.direction(of: after) ?? direction) == .rightToLeft
                return Caret(rect: line(at: rightToLeft ? rect.maxX : rect.minX, rect), source: .nextCharacter)
            }
            if var rect = try bounds(element, CFRange(location: caret, length: 0)) {
                if calibration.collapsedRangeIsLineAbove[bundleID] == true { rect.origin.y += rect.height }
                if isSane(rect, in: frame) {
                    return Caret(rect: line(at: rect.minX, rect), source: .collapsedRange)
                }
            }
            if let selection = AXDecode.markerRange(try element.value(kAXSelectedTextMarkerRangeAttribute)) {
                caretMarker = AXTextMarkerRangeCopyEndMarker(selection)
            }
        case .markers(_, let selectionEnd):
            caretMarker = selectionEnd
        }
        let rightToLeft = (before.flatMap(FieldClassifier.direction(of:)) ?? direction) == .rightToLeft
        if let caretMarker, let caret = try markerCaret(element, at: caretMarker, frame: frame, rightToLeft: rightToLeft) {
            return caret
        }
        return estimate(frame, style: style, rightToLeft: direction == .rightToLeft)
    }

    private static func isLineAbove(_ collapsed: CGRect, _ previousCharacter: CGRect) -> Bool {
        collapsed.height > 0 && abs(collapsed.maxY - previousCharacter.minY) < 1
            && abs(collapsed.minY - previousCharacter.minY) >= 1
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

    private static func markerCaret(
        _ element: AXElement, at marker: AXTextMarker, frame: CGRect?, rightToLeft: Bool
    ) throws(AXFailure) -> Caret? {
        if let rect = try markerBounds(element, from: marker, to: marker), isSane(rect, in: frame) {
            return Caret(rect: line(at: rect.minX, rect), source: .textMarker)
        }
        guard let previous = AXDecode.marker(try element.parameterized(
                  kAXPreviousTextMarkerForTextMarkerParameterizedAttribute, marker
              )),
              let rect = try markerBounds(element, from: previous, to: marker), isSane(rect, in: frame)
        else { return nil }
        return Caret(rect: line(at: rightToLeft ? rect.minX : rect.maxX, rect), source: .textMarker)
    }

    private static func estimate(_ frame: CGRect?, style: FieldStyle, rightToLeft: Bool) -> Caret {
        guard let frame else { return Caret(rect: .zero, source: .none) }
        let lineHeight = min(frame.height, max(12, (style.fontSize ?? 13) * 1.25))
        let y = frame.height <= lineHeight * 2 ? frame.midY - lineHeight / 2 : frame.minY + 4
        let x = rightToLeft ? frame.maxX - 5 : frame.minX + 4
        return Caret(rect: CGRect(x: x, y: y, width: 1, height: lineHeight), source: .estimate)
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
