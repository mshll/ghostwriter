import Foundation

/// What the user wrote in one field since it was first focused: the lines that changed, without text
/// Ghostwriter inserted. Holds counts and Ghostwriter's own insertions, never the typed keys.
public struct FieldWriting: Sendable {
    public static let minimumTyped = 20
    public static let minimumLength = WritingSession.minimumCharacters
    public static let maximumLength = 8_000
    static let contextLength = 1_000
    static let removableLength = 12
    static let wordBoundarySearch = 64

    private let baseline: String
    private var typedTotal = 0
    private var typedSinceFocus = 0
    private var insertionRuns: [[String]] = []
    private var lastWasInsertion = false

    public init(baseline: String) {
        self.baseline = baseline
    }

    public var hasTyped: Bool { typedTotal > 0 }

    public mutating func refocused() {
        typedSinceFocus = 0
        lastWasInsertion = false
    }

    public mutating func typed(_ count: Int) {
        typedTotal += count
        typedSinceFocus += count
        lastWasInsertion = false
    }

    public mutating func inserted(_ text: String) {
        if lastWasInsertion, !insertionRuns.isEmpty {
            insertionRuns[insertionRuns.count - 1].append(text)
        } else {
            insertionRuns.append([text])
        }
        lastWasInsertion = true
    }

    /// The text to store for `text`, the field's current contents, or nil when the user did not write enough of it.
    public func excerpt(of text: String) -> String? {
        guard typedSinceFocus >= Self.minimumTyped else { return nil }
        var changed = Self.changedLines(from: baseline, to: text)
        let notFound = insertionRuns.reduce(0) { $0 + Self.remove($1, from: &changed) }
        guard notFound <= typedTotal else { return nil }
        let excerpt = Self.tail(of: Self.droppingQuotedLines(changed))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return excerpt.count >= Self.minimumLength ? excerpt : nil
    }

    static func changedLines(from baseline: String, to text: String) -> String {
        let old = baseline.unicodeScalars
        let new = text.unicodeScalars
        var start = new.startIndex
        var oldStart = old.startIndex
        while start < new.endIndex, oldStart < old.endIndex, new[start] == old[oldStart] {
            new.formIndex(after: &start)
            old.formIndex(after: &oldStart)
        }
        var end = new.endIndex
        var oldEnd = old.endIndex
        while end > start, oldEnd > oldStart {
            let previous = new.index(before: end)
            let oldPrevious = old.index(before: oldEnd)
            guard new[previous] == old[oldPrevious] else { break }
            end = previous
            oldEnd = oldPrevious
        }
        guard start < end else { return "" }
        return String(Substring(new[lineStart(before: start, in: new)..<lineEnd(after: end, in: new)]))
    }

    private static func lineStart(before index: String.Index, in scalars: String.UnicodeScalarView) -> String.Index {
        var start = index
        for _ in 0..<contextLength {
            guard start > scalars.startIndex else { return start }
            let previous = scalars.index(before: start)
            if scalars[previous] == "\n" { return start }
            start = previous
        }
        while start < index, !scalars[start].properties.isWhitespace {
            scalars.formIndex(after: &start)
        }
        return start
    }

    private static func lineEnd(after index: String.Index, in scalars: String.UnicodeScalarView) -> String.Index {
        var end = index
        for _ in 0..<contextLength {
            guard end < scalars.endIndex, scalars[end] != "\n" else { return end }
            scalars.formIndex(after: &end)
        }
        while end > index, !scalars[scalars.index(before: end)].properties.isWhitespace {
            scalars.formIndex(before: &end)
        }
        return end
    }

    /// Removes a run of insertions as one span, else each long insertion on its own. Returns the length
    /// of the inserted text it could not find.
    private static func remove(_ run: [String], from text: inout String) -> Int {
        if run.count > 1, removeLast(run.joined(), from: &text) { return 0 }
        return run.reduce(0) { $0 + (removeLast($1, from: &text) ? 0 : $1.count) }
    }

    private static func removeLast(_ span: String, from text: inout String) -> Bool {
        guard span.count >= removableLength, let range = text.range(of: span, options: .backwards) else { return false }
        text.removeSubrange(range)
        return true
    }

    private static func droppingQuotedLines(_ text: String) -> String {
        guard text.contains(">") else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(">") }
            .joined(separator: "\n")
    }

    private static func tail(of text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > maximumLength else { return text }
        let cut = scalars.index(scalars.endIndex, offsetBy: -maximumLength)
        let limit = scalars.index(cut, offsetBy: wordBoundarySearch)
        let word = scalars[cut..<limit].firstIndex(where: \.properties.isWhitespace) ?? cut
        return String(Substring(scalars[word...]))
    }
}
