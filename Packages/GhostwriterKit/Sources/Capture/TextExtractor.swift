import ApplicationServices
import Foundation

/// Text around the caret, windowed and normalized. Offsets in `location` are raw UTF-16 offsets from the app.
struct ExtractedText {
    enum Location {
        case range(CFRange)
        case markers(selectionStart: AXTextMarker, selectionEnd: AXTextMarker)
    }

    var before: String
    var selected: String
    var after: String
    var totalLength: Int
    var path: ReadDiagnostics.TextPath
    var location: Location

    var characterBeforeCaret: Character? {
        selected.isEmpty ? before.last : selected.last
    }
}

enum TextExtractor {
    /// Chromium caps `AXNumberOfCharacters` and `AXValue` at this many UTF-16 units; `AXStringForRange` still reaches the rest.
    private static let chromiumLengthCap = 10_000

    static func range(_ element: AXElement, selection: CFRange, count: Int?) throws(AXFailure) -> ExtractedText? {
        let limit = FieldReader.maxLength
        guard (0...limit).contains(selection.location), (0...limit).contains(selection.length) else { return nil }
        let selectionEnd = selection.location + selection.length
        var count = count
        if let reported = count, reported == chromiumLengthCap || selectionEnd > reported {
            count = try markerLength(element) ?? (selectionEnd > reported ? nil : reported)
        }
        if let count {
            guard count <= limit, selectionEnd <= count else { return nil }
            if count > FieldReader.wholeValueLimit, let text = try windows(element, selection: selection, count: count) {
                return text
            }
        }
        guard let value = try element.string(kAXValueAttribute) else { return nil }
        let full = value as NSString
        guard full.length <= limit, selectionEnd <= full.length else { return nil }
        var text = slice(full, offset: 0, selection: try valueSelection(element, selection, in: full), total: full.length, path: .value)
        text.location = .range(selection)
        return text
    }

    /// Chromium leaves paragraph breaks out of the offsets of the selection and of `AXStringForRange`, but `AXValue`
    /// has them, so the selection lies further on in the value.
    private static func valueSelection(_ element: AXElement, _ selection: CFRange, in value: NSString) throws(AXFailure) -> CFRange {
        let end = selection.location + selection.length
        let tail = min(end, 32)
        guard tail > 0, value.range(of: "\n").location != NSNotFound,
              let indexedTail = try string(element, CFRange(location: end - tail, length: tail)),
              !indexedTail.isEqual(to: value.substring(with: NSRange(location: end - tail, length: tail))),
              let indexed = try string(element, CFRange(location: 0, length: end))
        else { return selection }
        return valueRange(of: selection, indexed: indexed, in: value) ?? selection
    }

    static func valueRange(of selection: CFRange, indexed: NSString, in value: NSString) -> CFRange? {
        let end = selection.location + selection.length
        guard indexed.length == end else { return nil }
        let newline = UInt16(UInt8(ascii: "\n"))
        var position = 0
        var start = 0
        for index in 0...end {
            if index == selection.location { start = position }
            guard index < end else { break }
            let unit = indexed.character(at: index)
            while position < value.length, unit != newline, value.character(at: position) == newline { position += 1 }
            guard position < value.length, value.character(at: position) == unit else { return nil }
            position += 1
        }
        return CFRange(location: start, length: position - start)
    }

    static func markers(_ element: AXElement) throws(AXFailure) -> ExtractedText? {
        guard let selection = AXDecode.markerRange(try element.value(kAXSelectedTextMarkerRangeAttribute)),
              let whole = AXDecode.markerRange(try element.parameterized(
                  kAXTextMarkerRangeForUIElementParameterizedAttribute, element.ref
              )) else { return nil }
        let selectionStart = AXTextMarkerRangeCopyStartMarker(selection)
        let selectionEnd = AXTextMarkerRangeCopyEndMarker(selection)
        var start = (marker: AXTextMarkerRangeCopyStartMarker(whole), isCut: false)
        var end = (marker: AXTextMarkerRangeCopyEndMarker(whole), isCut: false)
        let total = try length(element, from: start.marker, to: end.marker)
        var copiesSelection = true
        if total.map({ $0 > FieldReader.wholeValueLimit }) ?? true {
            let windowStart = try windowEdge(
                element, from: selectionStart, toward: start.marker, keeping: FieldReader.beforeWindow, backward: true
            )
            let windowEnd = try windowEdge(
                element, from: selectionEnd, toward: end.marker, keeping: FieldReader.afterWindow, backward: false
            )
            let readsWhole = windowStart == nil || windowEnd == nil
            guard !readsWhole || total.map({ $0 <= FieldReader.maxLength }) == true else { return nil }
            start = windowStart ?? start
            end = windowEnd ?? end
            copiesSelection = try length(element, from: selectionStart, to: selectionEnd)
                .map { $0 <= FieldReader.selectionLimit } ?? false
        }
        guard let before = try string(element, from: start.marker, to: selectionStart),
              let after = try string(element, from: selectionEnd, to: end.marker)
        else { return nil }
        let selected = copiesSelection ? try string(element, from: selectionStart, to: selectionEnd) ?? "" : ""

        let beforeStart = max(0, before.length - FieldReader.beforeWindow)
        let afterLength = min(after.length, FieldReader.afterWindow)
        return ExtractedText(
            before: clean(before.substring(from: beforeStart), cutAtStart: beforeStart > 0 || start.isCut),
            selected: selected.length <= FieldReader.selectionLimit ? clean(selected as String) : "",
            after: clean(after.substring(to: afterLength), cutAtEnd: afterLength < after.length || end.isCut),
            totalLength: total ?? before.length + selected.length + after.length,
            path: .textMarker,
            location: .markers(selectionStart: selectionStart, selectionEnd: selectionEnd)
        )
    }

    private static func windowEdge(
        _ element: AXElement, from caret: AXTextMarker, toward edge: AXTextMarker, keeping limit: Int, backward: Bool
    ) throws(AXFailure) -> (marker: AXTextMarker, isCut: Bool)? {
        func distance(to marker: AXTextMarker) throws(AXFailure) -> Int? {
            backward ? try length(element, from: marker, to: caret) : try length(element, from: caret, to: marker)
        }
        guard let toEdge = try distance(to: edge) else { return nil }
        if toEdge <= limit { return (edge, false) }
        // Engines count marker indexes from different anchors (Chromium: from the marker's node, but places index
        // markers from the document root), so a marker is kept only if it really lies about `limit` away.
        guard let index = AXDecode.int(try element.parameterized(kAXIndexForTextMarkerParameterizedAttribute, caret)),
              let marker = AXDecode.marker(try element.parameterized(
                  kAXTextMarkerForIndexParameterizedAttribute, NSNumber(value: backward ? index - limit : index + limit)
              )),
              let toMarker = try distance(to: marker), toMarker >= limit / 2, toMarker <= min(limit * 2, toEdge)
        else { return nil }
        return (marker, true)
    }

    private static func windows(_ element: AXElement, selection: CFRange, count: Int) throws(AXFailure) -> ExtractedText? {
        let selectionEnd = selection.location + selection.length
        let start = max(0, selection.location - FieldReader.beforeWindow)
        let end = min(count, selectionEnd + FieldReader.afterWindow)
        if selection.length <= FieldReader.selectionLimit {
            guard let text = try string(element, CFRange(location: start, length: end - start)) else { return nil }
            return slice(text, offset: start, selection: selection, total: count, path: .stringForRange)
        }
        guard let before = try string(element, CFRange(location: start, length: selection.location - start)),
              let after = try string(element, CFRange(location: selectionEnd, length: end - selectionEnd))
        else { return nil }
        return ExtractedText(
            before: clean(before as String, cutAtStart: start > 0),
            selected: "",
            after: clean(after as String, cutAtEnd: end < count),
            totalLength: count,
            path: .stringForRange,
            location: .range(selection)
        )
    }

    private static func slice(
        _ text: NSString, offset: Int, selection: CFRange, total: Int, path: ReadDiagnostics.TextPath
    ) -> ExtractedText {
        let selectionEnd = selection.location + selection.length
        let beforeStart = max(offset, selection.location - FieldReader.beforeWindow)
        let afterEnd = min(offset + text.length, selectionEnd + FieldReader.afterWindow)
        let before = text.substring(with: NSRange(location: beforeStart - offset, length: selection.location - beforeStart))
        let selected = selection.length <= FieldReader.selectionLimit
            ? text.substring(with: NSRange(location: selection.location - offset, length: selection.length))
            : ""
        let after = text.substring(with: NSRange(location: selectionEnd - offset, length: afterEnd - selectionEnd))
        return ExtractedText(
            before: clean(before, cutAtStart: beforeStart > 0),
            selected: clean(selected),
            after: clean(after, cutAtEnd: afterEnd < total),
            totalLength: total,
            path: path,
            location: .range(selection)
        )
    }

    /// A window cut out of longer text may start or end inside a surrogate pair or grapheme: drop that edge character.
    private static func clean(_ text: String, cutAtStart: Bool = false, cutAtEnd: Bool = false) -> String {
        var result = Substring(TextNormalizer.normalizeLineBreaks(text))
        if cutAtStart { result = result.dropFirst() }
        if cutAtEnd { result = result.dropLast() }
        return String(result)
    }

    private static func markerLength(_ element: AXElement) throws(AXFailure) -> Int? {
        guard let whole = AXDecode.markerRange(try element.parameterized(
            kAXTextMarkerRangeForUIElementParameterizedAttribute, element.ref
        )) else { return nil }
        return AXDecode.int(try element.parameterized(kAXLengthForTextMarkerRangeParameterizedAttribute, whole))
    }

    private static func length(
        _ element: AXElement, from start: AXTextMarker, to end: AXTextMarker
    ) throws(AXFailure) -> Int? {
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
        return AXDecode.int(try element.parameterized(kAXLengthForTextMarkerRangeParameterizedAttribute, range))
    }

    private static func string(_ element: AXElement, _ range: CFRange) throws(AXFailure) -> NSString? {
        guard let parameter = AXDecode.rangeValue(range),
              let text = AXDecode.string(try element.parameterized(kAXStringForRangeParameterizedAttribute, parameter))
        else { return nil }
        let result = text as NSString
        return result.length == range.length ? result : nil
    }

    private static func string(
        _ element: AXElement, from start: AXTextMarker, to end: AXTextMarker
    ) throws(AXFailure) -> NSString? {
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
        let value = try element.parameterized(kAXStringForTextMarkerRangeParameterizedAttribute, range)
        return AXDecode.string(value).map { $0 as NSString }
    }
}
