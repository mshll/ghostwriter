import Foundation

/// Drawn text changes only through the user's input: a newer candidate that extends it takes its place, so a
/// phrase grows without changing under the user's eyes. Newer candidates that disagree stay as alternates.
public enum ShownSuggestion {
    public static func merge(shown: [String], drawn: Bool, update: [String]) -> [String] {
        guard drawn, let current = shown.first else { return update }
        let key = normalized(current)
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
