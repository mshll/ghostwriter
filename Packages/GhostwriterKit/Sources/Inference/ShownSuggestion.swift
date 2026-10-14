import Foundation

/// A newer candidate that extends the shown text takes its place, so a phrase grows without changing under the
/// user's eyes. At line end, once the user pauses, a finished search whose best candidate disagrees with the
/// shown text replaces it: what shows first comes from unfinished or earlier searches and often is not their
/// best answer. Mid-line, the finished search's rerank picks worse than what streamed, so nothing is replaced.
public enum ShownSuggestion {
    public static let settleMilliseconds = 300.0

    public static func merge(shown: [String], drawn: Bool, update: [String], settled: Bool) -> [String] {
        guard drawn, let current = shown.first else { return update }
        let key = normalized(current)
        if settled, let best = update.first.map(normalized), !best.hasPrefix(key), !key.hasPrefix(best) {
            return (update + shown).uniqued()
        }
        let extending = update.first { normalized($0).hasPrefix(key) }
        return ([extending ?? current] + update + shown).uniqued()
    }

    public static func normalized(_ text: String) -> String {
        String(text.map { character -> Character in
            switch character {
            case "\u{2018}", "\u{2019}": "'"
            case "\u{201C}", "\u{201D}": "\""
            case "\u{00A0}": " "
            default: character
            }
        })
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
