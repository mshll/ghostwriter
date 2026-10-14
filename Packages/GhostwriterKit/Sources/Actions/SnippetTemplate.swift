enum SnippetTemplate {
    enum Piece: Equatable {
        case text(String)
        case date(String?)
        case time(String?)
        case clipboard
        case cursor
        case ai(String)
    }

    static func parse(_ body: String) -> [Piece] {
        var pieces: [Piece] = []
        var literal = ""
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            let next = body.index(after: index)
            if (character == "{" || character == "}"), next < body.endIndex, body[next] == character {
                literal.append(character)
                index = body.index(after: next)
                continue
            }
            if character == "{", let close = body[next...].firstIndex(of: "}"),
               let piece = placeholder(String(body[next..<close])) {
                if !literal.isEmpty { pieces.append(.text(literal)) }
                literal = ""
                pieces.append(piece)
                index = body.index(after: close)
                continue
            }
            literal.append(character)
            index = next
        }
        if !literal.isEmpty { pieces.append(.text(literal)) }
        return pieces
    }

    private static func placeholder(_ content: String) -> Piece? {
        let name: Substring
        let argument: String?
        if let colon = content.firstIndex(of: ":") {
            name = content[..<colon]
            argument = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        } else {
            name = Substring(content)
            argument = nil
        }
        switch (name.trimmingCharacters(in: .whitespaces).lowercased(), argument) {
        case ("date", let format): return .date(format.flatMap { $0.isEmpty ? nil : $0 })
        case ("time", let format): return .time(format.flatMap { $0.isEmpty ? nil : $0 })
        case ("clipboard", nil): return .clipboard
        case ("cursor", nil): return .cursor
        case ("ai", let instruction?) where !instruction.isEmpty: return .ai(instruction)
        default: return nil
        }
    }
}
