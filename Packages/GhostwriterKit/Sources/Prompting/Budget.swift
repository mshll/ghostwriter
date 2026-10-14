import GWCore

enum BudgetAllocator {
    /// Water-fills `total` level by level (lowest priority value first), then rounds each grant up
    /// to a multiple of `step`, capped at its demand, so sizes stay put across keystrokes.
    static func allocate(demands: [Int], priorities: [Int], total: Int, step: Int) -> [Int] {
        var granted = Array(repeating: 0, count: demands.count)
        var remaining = max(0, total)
        for level in Set(priorities).sorted() {
            var open = demands.indices.filter { priorities[$0] == level && demands[$0] > 0 }
            while remaining > 0, !open.isEmpty {
                guard remaining >= open.count else {
                    for index in open.prefix(remaining) { granted[index] += 1 }
                    remaining = 0
                    break
                }
                let share = remaining / open.count
                for index in open {
                    let grant = min(share, demands[index] - granted[index])
                    granted[index] += grant
                    remaining -= grant
                }
                open.removeAll { granted[$0] >= demands[$0] }
            }
        }
        return granted.indices.map { index in
            let grant = granted[index]
            guard grant > 0, step > 1 else { return grant }
            return min((grant + step - 1) / step * step, demands[index])
        }
    }
}

struct SectionFitter {
    enum Keep { case start, end }

    enum Boundary: CaseIterable { case paragraph, sentence, word }

    let counter: any TokenCounting

    static let marker = "⋯"
    static let maxCharactersPerToken = 8
    static let preferredUtilization = 0.85
    static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "؟"]
    static let fullWidthSentenceEnds: Set<Character> = ["。", "！", "？"]

    func measure(_ text: Substring, limit: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        guard limit > 0, !window(text, budget: limit, keep: .start).clipped else { return limit + 1 }
        return counter.countTokens(String(text))
    }

    func fit(_ text: Substring, budget: Int, keep: Keep) -> String {
        guard budget > 0, !text.isEmpty else { return "" }
        let (window, clipped) = window(text, budget: budget, keep: keep)
        let windowTokens = counter.countTokens(String(window))
        if !clipped, windowTokens <= budget { return String(window) }

        let cut = Cut(window: window, keep: keep)
        let estimate = cut.count * budget / max(windowTokens, 1)
        let hardLength = cut.longest(near: estimate) { counter.countTokens(cut.marked($0)) <= budget }
        let shortest = max(1, Int((Double(hardLength) * Self.preferredUtilization).rounded(.up)))
        for boundary in Boundary.allCases {
            if let length = cut.longestLength(at: boundary, from: hardLength, downTo: shortest) {
                return String(cut.trimmedKept(length))
            }
        }
        return hardLength > 0 ? cut.marked(hardLength) : ""
    }

    private func window(_ text: Substring, budget: Int, keep: Keep) -> (text: Substring, clipped: Bool) {
        let maxCharacters = budget * Self.maxCharactersPerToken
        switch keep {
        case .start:
            if let end = text.index(text.startIndex, offsetBy: maxCharacters, limitedBy: text.endIndex),
               end < text.endIndex {
                return (text[..<end], true)
            }
        case .end:
            if let start = text.index(text.endIndex, offsetBy: -maxCharacters, limitedBy: text.startIndex),
               start > text.startIndex {
                return (text[start...], true)
            }
        }
        return (text, false)
    }
}

private struct Cut {
    let window: Substring
    let keep: SectionFitter.Keep
    let positions: [String.Index]

    init(window: Substring, keep: SectionFitter.Keep) {
        self.window = window
        self.keep = keep
        positions = Array(window.indices) + [window.endIndex]
    }

    var count: Int { positions.count - 1 }

    func kept(_ length: Int) -> Substring {
        switch keep {
        case .start: window[positions[0]..<positions[length]]
        case .end: window[positions[count - length]..<positions[count]]
        }
    }

    func trimmedKept(_ length: Int) -> Substring {
        switch keep {
        case .start:
            let text = kept(length)
            return text[..<(text.lastIndex { !$0.isWhitespace }.map(text.index(after:)) ?? text.startIndex)]
        case .end:
            return kept(length).drop(while: \.isWhitespace)
        }
    }

    func marked(_ length: Int) -> String {
        switch keep {
        case .start: kept(length) + SectionFitter.marker
        case .end: SectionFitter.marker + kept(length)
        }
    }

    /// Largest length that fits, searched outward from `guess`, assuming longer text never needs fewer tokens.
    func longest(near guess: Int, where fits: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        var step = max(2, count / 256)
        var probe = min(max(guess, 0), count)
        if fits(probe) {
            low = probe
            while low < high {
                probe = min(high, low + step)
                guard fits(probe) else { high = probe - 1; break }
                low = probe
                step *= 2
            }
        } else {
            high = probe - 1
            while high > 0 {
                probe = max(0, high - step)
                guard !fits(probe) else { low = probe; break }
                high = probe - 1
                step *= 2
            }
        }
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(middle) { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func longestLength(at boundary: SectionFitter.Boundary, from longest: Int, downTo shortest: Int) -> Int? {
        guard longest >= shortest else { return nil }
        return stride(from: longest, through: shortest, by: -1).first { isBoundary(boundary, length: $0) }
    }

    private func character(_ offset: Int) -> Character { window[positions[offset]] }

    private func isBoundary(_ boundary: SectionFitter.Boundary, length: Int) -> Bool {
        switch keep {
        case .start: endsCleanly(at: length, boundary)
        case .end: startsCleanly(at: count - length, boundary)
        }
    }

    private func endsCleanly(at end: Int, _ boundary: SectionFitter.Boundary) -> Bool {
        guard end > 0, end < count else { return false }
        let last = character(end - 1)
        let next = character(end)
        switch boundary {
        case .paragraph:
            return next.isNewline && !last.isNewline
        case .sentence:
            return SectionFitter.fullWidthSentenceEnds.contains(last)
                || (SectionFitter.sentenceEnds.contains(last) && next.isWhitespace)
        case .word:
            return next.isWhitespace && !last.isWhitespace
        }
    }

    private func startsCleanly(at start: Int, _ boundary: SectionFitter.Boundary) -> Bool {
        guard start > 0, start < count, !character(start).isWhitespace else { return false }
        let previous = character(start - 1)
        switch boundary {
        case .paragraph:
            return previous.isNewline
        case .sentence:
            return SectionFitter.fullWidthSentenceEnds.contains(previous)
                || (previous.isWhitespace && start >= 2 && SectionFitter.sentenceEnds.contains(character(start - 2)))
        case .word:
            return previous.isWhitespace
        }
    }
}
