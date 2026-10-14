import Foundation

enum PartialWord {
    static func split(_ text: String) -> (head: Substring, partial: Substring) {
        var start = text.endIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            let character = text[previous]
            guard character.isWordCharacter, !character.isUnsegmentedScript else { break }
            start = previous
        }
        while start < text.endIndex, text[start].isApostrophe {
            start = text.index(after: start)
        }
        return (text[..<start], text[start...])
    }
}

extension Character {
    var isApostrophe: Bool { self == "'" || self == "\u{2019}" }

    var isWordCharacter: Bool {
        if isApostrophe { return true }
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return scalar == "\u{200C}" || scalar == "\u{200D}"
        }
    }

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

enum TextFolding {
    static func fold(_ text: String) -> String {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard folded.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) else { return folded }
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640:
                continue
            case 0x0622, 0x0623, 0x0625, 0x0671:
                scalars.append("\u{0627}")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
