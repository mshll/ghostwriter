import CoreGraphics
import Foundation
import GWCore

/// A piece of visible text and its frame in global screen coordinates (top-left origin).
struct TextChunk: Sendable, Hashable {
    var text: String
    var frame: CGRect
}

enum ScreenText {
    static let belowCaretPenalty: CGFloat = 2

    static func render(_ chunks: [TextChunk], for snapshot: FieldSnapshot, maxCharacters: Int) -> String? {
        let fieldText = normalized(snapshot.textBefore + snapshot.selectedText + snapshot.textAfter)
        var seen: Set<String> = [fieldText]
        let titles = [snapshot.windowTitle, snapshot.app.name].compactMap { $0.map(normalized) }.filter { !$0.isEmpty }
        seen.formUnion(titles)
        let anchor = caretAnchor(snapshot)
        let ranked = chunks
            .filter { !isFieldFrame($0.frame, snapshot.fieldFrame) }
            .map { (chunk: $0, score: score($0.frame, caret: anchor, field: snapshot.fieldFrame)) }
            .sorted { $0.score < $1.score }

        var parts: [String] = []
        var remaining = maxCharacters
        for (chunk, _) in ranked where remaining > 0 {
            guard let text = cleaned(chunk.text) else { continue }
            let key = normalized(text)
            if titles.contains(where: { key.contains($0) && key.count <= $0.count + 6 }) { continue }
            guard seen.insert(key).inserted else { continue }
            let isAbove = chunk.frame.midY <= anchor.midY
            let fitted = fit(text, into: remaining, keepEnd: isAbove)
            guard !fitted.isEmpty else { break }
            parts.append(fitted)
            remaining -= fitted.count + 1
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func score(_ frame: CGRect, caret: CGRect, field: CGRect) -> CGFloat {
        let vertical: CGFloat
        if frame.maxY <= caret.minY {
            vertical = caret.minY - frame.maxY
        } else if frame.minY >= caret.maxY {
            vertical = (frame.minY - caret.maxY) * belowCaretPenalty
        } else {
            vertical = 0
        }
        let column = field.isEmpty ? caret : field
        let horizontal = max(0, column.minX - frame.maxX, frame.minX - column.maxX)
        return vertical + horizontal
    }

    static func caretAnchor(_ snapshot: FieldSnapshot) -> CGRect {
        if snapshot.caretRect.height > 0 { return snapshot.caretRect }
        let field = snapshot.fieldFrame
        return CGRect(x: field.minX, y: field.minY, width: max(field.width, 1), height: 1)
    }

    static func isFieldFrame(_ frame: CGRect, _ field: CGRect) -> Bool {
        guard !field.isEmpty else { return false }
        let tolerance: CGFloat = 2
        return abs(frame.minX - field.minX) <= tolerance && abs(frame.minY - field.minY) <= tolerance
            && abs(frame.width - field.width) <= tolerance && abs(frame.height - field.height) <= tolerance
    }

    static func cleaned(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = stripTrailingClock(line.trimmingCharacters(in: .whitespaces))
            guard trimmed.unicodeScalars.filter(CharacterSet.letters.contains).count >= 3 else { return nil }
            let words = trimmed.split(whereSeparator: \.isWhitespace)
            let length = trimmed.count + 2 * trimmed.filter(\.isUnsegmentedScript).count
            guard words.count >= 2 || length >= 15 else { return nil }
            return trimmed
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    nonisolated(unsafe) private static let trailingClock =
        /\s*(?:[01]?\d|2[0-3])[:.][0-5]\d(?:\s?[AaPp]\.?[Mm]\.?)?\s*$/

    private static func stripTrailingClock(_ line: String) -> String {
        let stripped = line.replacing(trailingClock, with: "")
        guard stripped != line else { return line }
        return stripped.trimmingCharacters(in: CharacterSet(charactersIn: ",·•|-–—").union(.whitespaces))
    }

    static func fit(_ text: String, into limit: Int, keepEnd: Bool) -> String {
        guard text.count > limit else { return text }
        guard limit > 0 else { return "" }
        if keepEnd {
            let tail = text.suffix(limit)
            guard let space = tail.firstIndex(where: \.isWhitespace) else { return String(tail) }
            return String(tail[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let head = text.prefix(limit)
        guard let space = head.lastIndex(where: \.isWhitespace) else { return String(head) }
        return String(head[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func join(_ left: String, _ right: String, newLine: Bool) -> String {
        if left.isEmpty { return right }
        if newLine { return left + "\n" + right }
        let leftEnds = left.last.map { $0.isWhitespace } ?? true
        let rightStarts = right.first.map { $0.isWhitespace || ",.;:!?)]}%".contains($0) } ?? true
        return left + (leftEnds || rightStarts ? "" : " ") + right
    }
}

private extension Character {
    var isUnsegmentedScript: Bool {
        guard let value = unicodeScalars.first?.value else { return false }
        switch value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF,
             0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
