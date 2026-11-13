import Foundation

/// What the user wrote in one field since it was first focused: the lines that changed, without text
/// Ghostwriter inserted. Holds the field's text at focus, counts of typed keys, and Ghostwriter's own
/// insertions with the characters just before each.
public struct FieldWriting: Sendable {
    public static let minimumTyped = 20
    public static let minimumLength = WritingSession.minimumCharacters
    public static let maximumLength = 8_000
    static let contextLength = 1_000
    static let wordBoundarySearch = 64
    /// An insertion found more than once is told apart by the `anchorLength` characters before it,
    /// which a field read that lags behind the last typed keys places up to `anchorSlack` characters early.
    static let anchorLength = 24
    static let anchorSlack = 16

    struct Insertion {
        var text: String
        var before: String
        var startsField: Bool
    }

    enum Location {
        case found(Range<String.Index>)
        case missing
        case ambiguous
    }

    private let baseline: String
    private var typedTotal = 0
    private var typedSinceFocus = 0
    private var insertionRuns: [[Insertion]] = []
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

    /// `textBefore` is the field's text before the caret where `text` went in.
    public mutating func inserted(_ text: String, after textBefore: String) {
        guard !text.isEmpty else { return }
        if lastWasInsertion, let previous = insertionRuns.last?.last {
            let next = Self.insertion(text, after: previous.before + previous.text, startsField: previous.startsField)
            insertionRuns[insertionRuns.count - 1].append(next)
        } else {
            insertionRuns.append([Self.insertion(text, after: textBefore, startsField: true)])
        }
        lastWasInsertion = true
    }

    private static func insertion(_ text: String, after textBefore: String, startsField: Bool) -> Insertion {
        let cut = textBefore.index(textBefore.endIndex, offsetBy: -anchorLength, limitedBy: textBefore.startIndex)
        return Insertion(
            text: text,
            before: String(textBefore[(cut ?? textBefore.startIndex)...]),
            startsField: startsField && (cut ?? textBefore.startIndex) == textBefore.startIndex
        )
    }

    /// The text to store for `text`, the field's current contents, or nil when the user did not write
    /// enough of it or an insertion cannot be told apart from the user's own text.
    public func excerpt(of text: String) -> String? {
        guard typedSinceFocus >= Self.minimumTyped else { return nil }
        let region = Self.changedRegion(from: baseline, to: text)
        guard let inserted = insertedRanges(in: text, region: region) else { return nil }
        let excerpt = Self.tail(of: Self.droppingQuotedLines(Self.removing(inserted, from: text, in: region)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return excerpt.count >= Self.minimumLength ? excerpt : nil
    }

    /// Finds a run of insertions as one span, else each insertion of the run on its own. Nil when an
    /// insertion is found more than once and the text before it does not tell which, when two overlap,
    /// or when the inserted text no longer found is longer than all the user typed.
    private func insertedRanges(in text: String, region: Range<String.Index>) -> [Range<String.Index>]? {
        var ranges: [Range<String.Index>] = []
        var notFound = 0
        for run in insertionRuns {
            let whole = Insertion(text: run.map(\.text).joined(), before: run[0].before, startsField: run[0].startsField)
            switch Self.locate(whole, in: text, region: region) {
            case .found(let range):
                ranges.append(range)
                continue
            case .ambiguous:
                return nil
            case .missing where run.count == 1:
                notFound += whole.text.count
                continue
            case .missing:
                break
            }
            for insertion in run {
                switch Self.locate(insertion, in: text, region: region) {
                case .found(let range): ranges.append(range)
                case .ambiguous: return nil
                case .missing: notFound += insertion.text.count
                }
            }
        }
        guard notFound <= typedTotal else { return nil }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        guard zip(ranges, ranges.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else { return nil }
        return ranges
    }

    /// An insertion found more than once is the one nearest after its anchor.
    static func locate(_ insertion: Insertion, in text: String, region: Range<String.Index>) -> Location {
        let found = text[region].ranges(of: insertion.text)
        guard found.count > 1 else { return found.first.map { .found($0) } ?? .missing }
        let anchored = found.compactMap { range in lag(of: insertion, at: range.lowerBound, in: text).map { (range, $0) } }
        guard let nearest = anchored.min(by: { $0.1 < $1.1 }),
              anchored.count(where: { $0.1 == nearest.1 }) == 1 else { return .ambiguous }
        return .found(nearest.0)
    }

    /// How many characters lie between the end of the insertion's anchor and `position`, if at most `anchorSlack`.
    private static func lag(of insertion: Insertion, at position: String.Index, in text: String) -> Int? {
        var end = position
        for lag in 0...anchorSlack {
            let before = text[..<end]
            if insertion.startsField ? before == insertion.before : before.hasSuffix(insertion.before) { return lag }
            guard end > text.startIndex else { return nil }
            text.formIndex(before: &end)
        }
        return nil
    }

    private static func removing(_ ranges: [Range<String.Index>], from text: String, in region: Range<String.Index>) -> String {
        var kept = ""
        var start = region.lowerBound
        for range in ranges {
            kept += text[start..<range.lowerBound]
            start = range.upperBound
        }
        return kept + text[start..<region.upperBound]
    }

    static func changedRegion(from baseline: String, to text: String) -> Range<String.Index> {
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
        guard start < end else { return start..<start }
        return lineStart(before: start, in: new)..<lineEnd(after: end, in: new)
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
