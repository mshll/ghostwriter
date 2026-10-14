import Foundation

/// A proofread of the text that ends at the caret. Applying it deletes `deleteCount` characters backward and
/// types `insertion`; applying `reverted` afterwards restores the original.
public struct Proofread: Sendable, Hashable {
    public struct Change: Sendable, Hashable {
        public var old: String
        public var new: String
    }

    public let original: String
    public let corrected: String

    public init(original: String, corrected: String) {
        self.original = original
        self.corrected = corrected
    }

    /// Keeps the whitespace around `original`, which the model trims.
    public init(original: String, modelOutput: String) {
        let core = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = original.prefix(while: \.isWhitespace)
        let trailing = String(original.reversed().prefix(while: \.isWhitespace).reversed())
        self.init(original: original, corrected: leading + core + trailing)
    }

    public var reverted: Proofread { Proofread(original: corrected, corrected: original) }

    public var isUnchanged: Bool { original == corrected }

    /// Counted in grapheme clusters: one Backspace press each.
    public var deleteCount: Int { original.count - keptCount }

    public var insertion: String { String(corrected.dropFirst(keptCount)) }

    private var keptCount: Int { zip(original, corrected).prefix { $0 == $1 }.count }

    public var changes: [Change] {
        let old = Self.words(original)
        let new = Self.words(corrected)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Change] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
                i += 1
                j += 1
                continue
            }
            let oldStart = i
            let newStart = j
            while i < old.count, removed.contains(i) { i += 1 }
            while j < new.count, inserted.contains(j) { j += 1 }
            guard i > oldStart || j > newStart else { break }
            result.append(Change(
                old: old[oldStart..<i].joined(separator: " "),
                new: new[newStart..<j].joined(separator: " ")
            ))
        }
        return result
    }

    /// A proofread that changes much of the text has rewritten or answered it instead of correcting it.
    public var rewritesTooMuch: Bool {
        let edits = Array(corrected).difference(from: Array(original)).count
        return Double(edits) > max(8, 0.3 * Double(original.count + corrected.count))
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
