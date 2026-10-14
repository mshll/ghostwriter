import Foundation
import GWCore
import Inference
import Proofing

struct ActiveSuggestion: Equatable {
    enum Kind: Equatable {
        case completion
        case draft
        case typos([TypoFix])
    }

    var fieldID: FieldID
    var anchor: String
    var candidates: [String]
    var kind: Kind
    var isDrawn = false

    var text: String { candidates.first ?? "" }

    func advanced(to textBefore: String) -> ActiveSuggestion? {
        if case .typos = kind {
            return textBefore == anchor ? self : nil
        }
        guard let appended = TextContinuation.appended(
            from: ShownSuggestion.normalized(anchor), to: ShownSuggestion.normalized(textBefore)
        ) else {
            return nil
        }
        let typed = String(appended)
        guard !typed.isEmpty else { return self }
        let remaining = candidates.compactMap { candidate -> String? in
            let key = ShownSuggestion.normalized(candidate)
            guard key.hasPrefix(typed), key.count > typed.count else { return nil }
            return String(candidate.dropFirst(typed.count))
        }
        guard !remaining.isEmpty else { return nil }
        return ActiveSuggestion(fieldID: fieldID, anchor: textBefore, candidates: remaining, kind: kind, isDrawn: isDrawn)
    }

    func merged(with newer: ActiveSuggestion, settled: Bool) -> ActiveSuggestion {
        guard newer.anchor == anchor, newer.kind == kind else { return newer }
        let candidates = ShownSuggestion.merge(shown: self.candidates, drawn: isDrawn, update: newer.candidates, settled: settled)
        return ActiveSuggestion(fieldID: fieldID, anchor: anchor, candidates: candidates, kind: kind, isDrawn: isDrawn)
    }
}

enum TextContinuation {
    /// Long fields are read through a window that drops leading text as the caret moves (3300 UTF-16 units).
    private static let windowedLength = 3_000
    private static let tailLength = 256
    private static let maxAppended = 256

    static func appended(from old: String, to new: String) -> Substring? {
        if new.hasPrefix(old) { return new.dropFirst(old.count) }
        guard old.utf16.count >= windowedLength, new.utf16.count >= windowedLength else { return nil }
        let tail = old.suffix(tailLength)
        guard let range = new.range(of: tail, options: .backwards),
              new.distance(from: range.upperBound, to: new.endIndex) <= maxAppended else { return nil }
        return new[range.upperBound...]
    }
}
