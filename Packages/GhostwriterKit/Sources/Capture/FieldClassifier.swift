import ApplicationServices
import Foundation
import GWCore

enum FieldClassifier {
    struct Input {
        var bundleID: String
        var role: String
        var label: String?
        var domIdentifier: String?
        var host: String?
        var isWeb: Bool
        var isTerminal: Bool
        var isCodeEditor: Bool
        var isAgentComposer: Bool
    }

    static func kind(_ input: Input) -> FieldKind {
        let id = input.bundleID
        let host = input.host
        func hostIn(_ patterns: [String]) -> Bool {
            host.map { DomainPattern.matchesAny(patterns, host: $0) } ?? false
        }

        if input.isTerminal { return .terminal }
        if input.isAgentComposer { return .aiPrompt }
        if input.isCodeEditor { return .code }
        if looksLikeSearch(input) { return .search }
        if AppCatalog.aiApps.contains(id) || hostIn(AppCatalog.aiHosts) { return .aiPrompt }
        if AppCatalog.mailApps.contains(id) || hostIn(AppCatalog.mailHosts) { return .email }
        if AppCatalog.chatApps.contains(id) || hostIn(AppCatalog.chatHosts) { return .chat }
        if AppCatalog.documentApps.contains(id) || hostIn(AppCatalog.documentHosts) { return .document }
        if input.isWeb, input.role == kAXTextFieldRole || input.role == kAXComboBoxRole { return .form }
        return .unknown
    }

    private static func looksLikeSearch(_ input: Input) -> Bool {
        guard input.role == kAXTextFieldRole || input.role == kAXComboBoxRole else { return false }
        let hints = [input.label, input.domIdentifier].compactMap { $0?.lowercased() }
        return hints.contains { $0.contains("search") }
    }

    static func direction(before: String, after: String) -> WritingDirection {
        let paragraphStart = before.lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex
        let paragraphTail = after.prefix { !$0.isNewline }
        let paragraph = Array(before[paragraphStart...].unicodeScalars) + Array(paragraphTail.unicodeScalars)
        if let first = paragraph.lazy.compactMap(strongDirection).first { return first }
        return before.unicodeScalars.reversed().lazy.compactMap(strongDirection).first ?? .leftToRight
    }

    static func direction(of character: Character) -> WritingDirection? {
        character.unicodeScalars.lazy.compactMap(strongDirection).first
    }

    private static func strongDirection(_ scalar: Unicode.Scalar) -> WritingDirection? {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return isRightToLeftScript(scalar.value) ? .rightToLeft : .leftToRight
        default:
            return nil
        }
    }

    private static func isRightToLeftScript(_ value: UInt32) -> Bool {
        switch value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: true
        default: false
        }
    }
}

enum SecretFieldHints {
    private static let passwordWords = [
        "password", "passcode", "passwort", "mot de passe", "contraseña", "senha", "wachtwoord", "пароль",
        "كلمة المرور", "كلمة السر", "パスワード", "密码", "密碼", "비밀번호",
    ]
    private static let credentialAutofillTypes: Set<String> = ["credentials", "strong password"]

    static func mentionsPassword(_ label: String) -> Bool {
        passwordWords.contains {
            label.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }

    static func isCredentialAutofill(_ autofillType: String?) -> Bool {
        autofillType.map(credentialAutofillTypes.contains) ?? false
    }
}

/// Browsers show web pages over these schemes; anything else there is browser or extension UI, such as a
/// password manager popup. Other apps load their own UI over custom schemes, so only extension pages are refused.
enum PageScheme {
    private static let webPageSchemes: Set<String> = ["http", "https", "file", "about"]

    static func isReadable(_ url: URL, inBrowser: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return inBrowser ? webPageSchemes.contains(scheme) : !scheme.hasSuffix("extension")
    }
}

enum TextNormalizer {
    static func normalizeLineBreaks(_ text: String) -> String {
        guard text.contains(where: { $0 == "\r\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) else {
            return text
        }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "\r\n", "\r", "\u{2028}", "\u{2029}": result.append("\n")
            default: result.append(character)
            }
        }
        return result
    }
}
