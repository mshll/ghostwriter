import AppKit
import ApplicationServices
import Capture
import GWCore

/// Moves the caret of the focused field through positions and prints, for each, the caret Ghostwriter places and the
/// raw AX answers behind it. With `--truth` it also finds the caret the app draws: frames of the field captured over
/// a blink cycle differ only where the caret blinks. Prints field text: run it only on test text.
@MainActor
enum Sweep {
    struct Options {
        var positions: [String] = []
        var truth = false
        var settle = 0.25
    }

    static func run(_ arguments: [String]) {
        var options = Options()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--truth": options.truth = true
            case "--settle": options.settle = rest.popFirst().flatMap(Double.init) ?? options.settle
            default: options.positions.append(argument)
            }
        }
        let tracker = FocusTracker()
        var source = ReadDiagnostics.CaretSource.none
        tracker.onDiagnostics = { source = $0.caretSource }
        Task {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let field = AXTools.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
            else {
                print("no focused element")
                exit(1)
            }
            print("app \(app.bundleIdentifier ?? "-") frame \(rect(frame(field)))")
            for position in options.positions.isEmpty ? ["here"] : options.positions {
                let text = (AXTools.value(field, kAXValueAttribute) as? String ?? "") as NSString
                if position != "here" {
                    let location = position == "end" ? text.length : Int(position) ?? 0
                    var range = CFRange(location: location, length: 0)
                    guard let value = AXValueCreate(.cfRange, &range),
                          AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success
                    else {
                        print("cannot select \(location)")
                        continue
                    }
                    await pause(options.settle)
                }
                let snapshot = await tracker.snapshot()
                let caret = caretIndex(field) ?? -1
                let before = snapshot.map { $0.textBefore.last.map(String.init) ?? "" } ?? character(text, endingAt: caret)
                let after = snapshot.map { $0.textAfter.first.map(String.init) ?? "" } ?? character(text, startingAt: caret)
                var line = "pos=\(caret) before=\(quote(before)) after=\(quote(after))"
                line += " gw=\(source.rawValue) \(snapshot.map { rect($0.caretRect) } ?? "-")"
                if options.truth { line += " truth=\(await drawnCaret(in: frame(field)).map(rect) ?? "-")" }
                print(line)
                print("    " + rawAnswers(field, text: text, caret: caret))
            }
            exit(0)
        }
    }

    private static func rawAnswers(_ field: AXUIElement, text: NSString, caret: Int) -> String {
        var parts: [String] = []
        if caret > 0 {
            let previous = text.rangeOfComposedCharacterSequence(at: caret - 1)
            parts.append("prev=\(bounds(field, CFRange(location: previous.location, length: previous.length)))")
        }
        if caret < text.length {
            let next = text.rangeOfComposedCharacterSequence(at: caret)
            parts.append("next=\(bounds(field, CFRange(location: next.location, length: next.length)))")
        }
        parts.append("zero=\(bounds(field, CFRange(location: caret, length: 0)))")
        if let selection = AXTools.value(field, kAXSelectedTextMarkerRangeAttribute),
           CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() {
            let end = AXTextMarkerRangeCopyEndMarker(unsafeDowncast(selection, to: AXTextMarkerRange.self))
            parts.append("marker=\(markerBounds(field, end, end))")
            if let previous = AXTools.parameterized(field, kAXPreviousTextMarkerForTextMarkerParameterizedAttribute, end),
               CFGetTypeID(previous) == AXTextMarkerGetTypeID() {
                parts.append("markerPrev=\(markerBounds(field, unsafeDowncast(previous, to: AXTextMarker.self), end))")
            }
            if let next = marker(field, kAXNextTextMarkerForTextMarkerParameterizedAttribute, end) {
                parts.append("markerNext=\(markerBounds(field, end, next))")
                if let back = marker(field, kAXPreviousTextMarkerForTextMarkerParameterizedAttribute, next) {
                    parts.append("markerNextBack=\(markerBounds(field, back, next)) zeroAtBack=\(markerBounds(field, back, back))")
                }
            }
            var steps: [String] = []
            var later = end
            for _ in 0..<4 {
                guard let earlier = marker(field, kAXPreviousTextMarkerForTextMarkerParameterizedAttribute, later) else { break }
                steps.append(markerBounds(field, earlier, later))
                later = earlier
            }
            parts.append("markerBack=[\(steps.joined(separator: " "))]")
            if let line = AXTools.parameterized(field, kAXLineTextMarkerRangeForTextMarkerParameterizedAttribute, end),
               CFGetTypeID(line) == AXTextMarkerRangeGetTypeID() {
                parts.append("markerLine=\(rectValue(AXTools.parameterized(field, kAXBoundsForTextMarkerRangeParameterizedAttribute, line) ?? kCFNull))")
            }
        }
        var names: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(field, &names) == .success,
           (names as? [String] ?? []).contains(kAXLineForIndexParameterizedAttribute) {
            let number = AXTools.value(field, kAXInsertionPointLineNumberAttribute) as? Int
            let index = AXTools.parameterized(field, kAXLineForIndexParameterizedAttribute, caret as CFNumber) as? Int
            parts.append("line=\(index.map(String.init) ?? "-")/ip=\(number.map(String.init) ?? "-")")
            if let index, let value = AXTools.parameterized(field, kAXRangeForLineParameterizedAttribute, index as CFNumber) {
                var range = CFRange()
                if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) {
                    parts.append("lineRange=\(range.location)+\(range.length) lineBox=\(bounds(field, range))")
                }
            }
        }
        return parts.joined(separator: " ")
    }

    /// Captures the field a few times over one blink cycle; the pixels that change are the caret.
    private static func drawnCaret(in frame: CGRect?) async -> CGRect? {
        guard let frame else { return nil }
        let region = frame.insetBy(dx: -4, dy: -4).integral
        let directory = FileManager.default.temporaryDirectory
        var images: [CGImage] = []
        for index in 0..<6 {
            let file = directory.appendingPathComponent("gw-sweep-\(index).png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", file.path]
            do {
                try process.run()
            } catch {
                print("screencapture failed: \(error)")
                return nil
            }
            process.waitUntilExit()
            if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { images.append(image) }
            await pause(0.12)
        }
        guard let first = images.first, let base = pixels(first) else { return nil }
        let width = first.width, height = first.height
        var changed = [Bool](repeating: false, count: width * height)
        for image in images.dropFirst() {
            guard image.width == width, image.height == height, let other = pixels(image) else { continue }
            for index in 0..<(width * height) where !changed[index] {
                let offset = index * 4
                let difference = (0..<3).reduce(0) { $0 + abs(Int(base[offset + $1]) - Int(other[offset + $1])) }
                if difference > 90 { changed[index] = true }
            }
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where changed[y * width + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let scale = CGFloat(width) / region.width
        return CGRect(
            x: region.minX + CGFloat(minX) / scale, y: region.minY + CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
        )
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? data : nil
    }

    private static func pause(_ seconds: Double) async {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            print("cancelled: \(error)")
        }
    }

    private static func caretIndex(_ field: AXUIElement) -> Int? {
        var range = CFRange()
        guard let value = AXTools.value(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return range.location + range.length
    }

    private static func frame(_ field: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let position = AXTools.value(field, kAXPositionAttribute), let extent = AXTools.value(field, kAXSizeAttribute),
              AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(extent, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func character(_ text: NSString, endingAt index: Int) -> String {
        guard index > 0, index <= text.length else { return "" }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: index - 1))
    }

    private static func character(_ text: NSString, startingAt index: Int) -> String {
        guard index >= 0, index < text.length else { return "" }
        return text.substring(with: text.rangeOfComposedCharacterSequence(at: index))
    }

    private static func bounds(_ field: AXUIElement, _ range: CFRange) -> String {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range),
              let value = AXTools.parameterized(field, kAXBoundsForRangeParameterizedAttribute, parameter)
        else { return "-" }
        return rectValue(value)
    }

    private static func marker(_ field: AXUIElement, _ attribute: String, _ from: AXTextMarker) -> AXTextMarker? {
        guard let value = AXTools.parameterized(field, attribute, from), CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXTextMarker.self)
    }

    private static func markerBounds(_ field: AXUIElement, _ start: AXTextMarker, _ end: AXTextMarker) -> String {
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
        guard let value = AXTools.parameterized(field, kAXBoundsForTextMarkerRangeParameterizedAttribute, range) else { return "-" }
        return rectValue(value)
    }

    private static func rectValue(_ value: CFTypeRef) -> String {
        var rect = CGRect.zero
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &rect)
        else { return "?" }
        return self.rect(rect)
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\u{2028}", with: "\\u2028") + "\""
    }

    private static func rect(_ rect: CGRect?) -> String {
        guard let rect else { return "-" }
        return String(format: "{%.1f,%.1f %.1fx%.1f}", rect.minX, rect.minY, rect.width, rect.height)
    }
}
