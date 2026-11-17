import Foundation

/// The input box of a coding agent running in a terminal, found in the terminal's screen text. The prompt line
/// must be closed off by a rule or box border directly above and below: a shell prompt or an option menu uses
/// the same glyphs on a line of its own.
struct TerminalAgentPrompt: Equatable {
    var textBefore: String
    var textAfter: String
    /// The screen character the caret follows, as a UTF-16 range of the screen text.
    var anchor: NSRange
    /// The first cell of the draft on the prompt line, when that line has one.
    var draftStart: Int?
    /// The agent's output above the box, without rules and the status line over the box.
    var transcript: String

    static let scannedRows = 200
    private static let maxDraftRows = 60
    private static let minRuleLength = 8
    private static let rightAlignedIndent = 20

    private static let markers: Set<Character> = ["❯", "›", ">"]
    private static let verticals: Set<Character> = ["│", "┃"]
    private static let horizontals: Set<Character> = ["─", "━", "═"]
    private static let topLeft: Set<Character> = ["╭", "┌", "┏"]
    private static let topRight: Set<Character> = ["╮", "┐", "┓"]
    private static let bottomLeft: Set<Character> = ["╰", "└", "┗"]
    private static let bottomRight: Set<Character> = ["╯", "┘", "┛"]

    private struct Row {
        var location: Int
        var text: NSString

        var string: String { text as String }
    }

    private struct Prefix {
        var indent: Int
        var boxed: Bool
        var contentColumn: Int
    }

    private struct Segment {
        var start: Int
        var raw: NSString
        var isFull: Bool

        var trimmed: NSString { raw.trimmingTrailingWhitespace }
    }

    /// `cursor` is the terminal's cursor as a UTF-16 offset of `screen`. Agents that draw their own caret leave
    /// the terminal cursor outside the box; then the caret is taken to be at the end of the draft.
    static func find(in screen: String, cursor: Int?) -> TerminalAgentPrompt? {
        let rows = rows(of: screen as NSString)
        guard let promptIndex = rows.lastIndex(where: { prefix(of: $0.string) != nil }),
              let prefix = prefix(of: rows[promptIndex].string), promptIndex > 0,
              let segments = segments(rows, promptIndex: promptIndex, prefix: prefix)
        else { return nil }
        let promptRow = rows[promptIndex]
        let firstText = segments[0].trimmed as String
        if firstText.first?.isNumber == true, firstText.drop(while: \.isNumber).hasPrefix(". ") { return nil }

        let regionEnd = segments[segments.count - 1].start + segments[segments.count - 1].raw.length
        let caret: (segment: Int, offset: Int)
        if let cursor, cursor >= segments[0].start, cursor <= regionEnd {
            if cursor == segments[0].start { return empty(promptRow, prefix: prefix, rows: rows, promptIndex: promptIndex) }
            let segment = segments.lastIndex { $0.start <= cursor } ?? 0
            caret = (segment, min(cursor - segments[segment].start, segments[segment].raw.length))
        } else {
            let last = segments.count - 1
            var length = segments[last].raw.length
            if prefix.boxed {
                length = segments[last].trimmed.length
            } else if length > 0, segments[last].raw.character(at: length - 1) == 0x20 {
                length -= 1
            }
            caret = (last, length)
        }

        var before = ""
        var anchor: NSRange?
        for (index, segment) in segments.enumerated() where index <= caret.segment {
            let piece = index == caret.segment ? segment.raw.substring(to: caret.offset) as NSString : segment.trimmed
            if index > 0, segment.trimmed.length > 0, !segments[index - 1].isFull, !before.isEmpty { before += " " }
            before += piece as String
            if piece.length > 0 {
                let last = piece.rangeOfComposedCharacterSequence(at: piece.length - 1)
                anchor = NSRange(location: segment.start + last.location, length: last.length)
            }
        }
        guard let anchor, !before.isEmpty else { return empty(promptRow, prefix: prefix, rows: rows, promptIndex: promptIndex) }

        let caretSegment = segments[caret.segment]
        var after = (caretSegment.raw.substring(from: caret.offset) as NSString).trimmingTrailingWhitespace as String
        for (index, segment) in segments.enumerated() where index > caret.segment && segment.trimmed.length > 0 {
            if !segments[index - 1].isFull, !(after.isEmpty && before.last == " ") { after += " " }
            after += segment.trimmed as String
        }
        return TerminalAgentPrompt(
            textBefore: before,
            textAfter: after,
            anchor: anchor,
            draftStart: draftStart(promptRow, prefix: prefix),
            transcript: transcript(rows[..<(promptIndex - 1)])
        )
    }

    private static func empty(_ row: Row, prefix: Prefix, rows: [Row], promptIndex: Int) -> TerminalAgentPrompt {
        let cell = max(0, min(prefix.contentColumn, row.text.length) - 1)
        return TerminalAgentPrompt(
            textBefore: "",
            textAfter: "",
            anchor: NSRange(location: row.location + cell, length: 1),
            draftStart: draftStart(row, prefix: prefix),
            transcript: transcript(rows[..<(promptIndex - 1)])
        )
    }

    private static func draftStart(_ row: Row, prefix: Prefix) -> Int? {
        prefix.contentColumn < row.text.length ? row.location + prefix.contentColumn : nil
    }

    private static func rows(of screen: NSString) -> [Row] {
        var rows: [Row] = []
        var end = screen.length
        while rows.count < scannedRows {
            let newline = screen.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: end))
            let start = newline.location == NSNotFound ? 0 : newline.location + 1
            let text = screen.substring(with: NSRange(location: start, length: end - start)) as NSString
            rows.append(Row(location: start, text: text))
            guard newline.location != NSNotFound else { break }
            end = newline.location
        }
        return rows.reversed()
    }

    /// Box-drawing glyphs, markers and spaces are one UTF-16 unit each, so columns in the prefix are offsets.
    private static func prefix(of text: String) -> Prefix? {
        var index = text.startIndex
        var column = 0
        func skipSpaces() {
            while index < text.endIndex, text[index] == " " {
                index = text.index(after: index)
                column += 1
            }
        }
        skipSpaces()
        let indent = column
        var boxed = false
        if index < text.endIndex, verticals.contains(text[index]) {
            boxed = true
            index = text.index(after: index)
            column += 1
            guard index < text.endIndex, text[index] == " " else { return nil }
            skipSpaces()
        }
        guard index < text.endIndex, markers.contains(text[index]) else { return nil }
        index = text.index(after: index)
        column += 1
        if index == text.endIndex, !boxed { return Prefix(indent: indent, boxed: false, contentColumn: column) }
        guard index < text.endIndex, text[index] == " " else { return nil }
        return Prefix(indent: indent, boxed: boxed, contentColumn: column + 1)
    }

    private static func segments(_ rows: [Row], promptIndex: Int, prefix: Prefix) -> [Segment]? {
        let above = rows[promptIndex - 1].string
        let width: Int
        if prefix.boxed {
            guard isBorder(above, left: topLeft, right: topRight) else { return nil }
            width = columns(above.trimmingTrailingWhitespace) - 2
        } else {
            guard isRule(above) else { return nil }
            width = columns(above.trimmingTrailingWhitespace)
        }
        var segments: [Segment] = []
        var index = promptIndex
        while index < rows.count, index - promptIndex < maxDraftRows {
            let row = rows[index]
            let text = row.string
            if index > promptIndex {
                if prefix.boxed ? isBorder(text, left: bottomLeft, right: bottomRight) : isRule(text) { return segments }
                guard isContinuation(text, prefix: prefix) else { return nil }
            }
            var end = row.text.length
            if prefix.boxed {
                let trimmed = row.text.trimmingTrailingWhitespace
                guard let last = (trimmed as String).last, verticals.contains(last) else { return nil }
                end = trimmed.length - 1
            }
            let start = min(prefix.contentColumn, end)
            let raw = row.text.substring(with: NSRange(location: start, length: end - start)) as NSString
            let used = prefix.contentColumn + columns(raw.trimmingTrailingWhitespace as String)
            segments.append(Segment(start: row.location + start, raw: raw, isFull: used >= width))
            index += 1
        }
        return nil
    }

    private static func isContinuation(_ text: String, prefix: Prefix) -> Bool {
        let lead = Array(text.prefix(prefix.contentColumn))
        if lead.allSatisfy({ $0 == " " }) { return !prefix.boxed }
        guard prefix.boxed, lead.count == prefix.contentColumn, verticals.contains(lead[prefix.indent]) else { return false }
        return lead.enumerated().allSatisfy { $0.offset == prefix.indent || $0.element == " " }
    }

    private static func isRule(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= minRuleLength && trimmed.allSatisfy(horizontals.contains)
    }

    private static func isBorder(_ text: String, left: Set<Character>, right: Set<Character>) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minRuleLength, let first = trimmed.first, let last = trimmed.last,
              left.contains(first), right.contains(last) else { return false }
        return trimmed.dropFirst().dropLast().allSatisfy(horizontals.contains)
    }

    private static func transcript(_ rows: ArraySlice<Row>) -> String {
        var lines = rows.map { $0.string.trimmingTrailingWhitespace }
        while let last = lines.last,
              last.isEmpty || isRule(last) || last.prefix(while: { $0 == " " }).count >= rightAlignedIndent {
            lines.removeLast()
        }
        var kept: [String] = []
        for line in lines where !isRule(line) {
            if line.isEmpty, kept.last?.isEmpty ?? true { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Terminal cells the text takes: East Asian wide characters and emoji take two.
    static func columns(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
                 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
                count + 2
            case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F:
                count
            default:
                count + 1
            }
        }
    }
}

private extension NSString {
    var trimmingTrailingWhitespace: NSString {
        var end = length
        while end > 0, character(at: end - 1) == 0x20 || character(at: end - 1) == 0x09 { end -= 1 }
        return end == length ? self : substring(to: end) as NSString
    }
}

private extension String {
    var trimmingTrailingWhitespace: String {
        String(self[..<(lastIndex { $0 != " " && $0 != "\t" }.map(index(after:)) ?? startIndex)])
    }
}
