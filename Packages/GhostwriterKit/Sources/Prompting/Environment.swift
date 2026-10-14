import Foundation
import GWCore

enum EnvironmentLines {
    static let valueLimit = 100
    static let windowTitlePrefix = "The window is titled \""
    static let fieldLabelPrefix = "The field is labeled \""

    /// Starts of the environment lines a draft can echo once it runs past the user's text onto a new line. Lines
    /// that also open ordinary sentences ("My name is", "It is a") are cut to forms the user rarely types.
    static let stopStarts: [String] = {
        let preambleStart = String(PromptText.preamble.prefix { $0 != "." }) + "."
        var starts = [preambleStart, "I am typing in ", "The website is ", windowTitlePrefix, fieldLabelPrefix]
        starts += FieldKind.allCases.compactMap(describe)
        starts += weekdays.map { "It is \($0), " }
        let languages = Locale.LanguageCode.isoLanguageCodes.filter { $0.identifier.count == 2 }
        starts += Set(languages.compactMap { LanguageDetector.englishName(of: $0.identifier) }).sorted().map { "I am writing in \($0)." }
        return starts.map { "\n" + $0 }
    }()

    static func make(for context: PromptContext) -> [String] {
        var lines: [String] = []
        let app = singleLine(context.appName)
        if let name = singleLine(context.userName) { lines.append("My name is \(name).") }
        if let app { lines.append("I am typing in \(app).") }
        if let title = singleLine(context.windowTitle), title.caseInsensitiveCompare(app ?? "") != .orderedSame {
            lines.append(windowTitlePrefix + title + "\".")
        }
        if let domain = singleLine(context.domain) { lines.append("The website is \(domain).") }
        if let kind = describe(context.fieldKind) { lines.append(kind) }
        if let label = singleLine(context.fieldLabel) { lines.append(fieldLabelPrefix + label + "\".") }
        return lines
    }

    /// Lines that can appear or change while the user types in one field. They go next to the typed text, so a
    /// change only invalidates the end of the cached prompt.
    static func volatile(for context: PromptContext, language: String?, timeZone: TimeZone) -> [String] {
        var lines: [String] = []
        if let language, let name = LanguageDetector.englishName(of: language) {
            lines.append("I am writing in \(name).")
        }
        if includesDate(context, language: language) {
            lines.append(dateLine(context.now, timeZone: timeZone))
        }
        return lines
    }

    static func includesDate(_ context: PromptContext, language: String?) -> Bool {
        context.keepsDate || TemporalCues.isRelevant(fieldKind: context.fieldKind, textBefore: context.textBefore, language: language)
    }

    static func describe(_ kind: FieldKind) -> String? {
        switch kind {
        case .email: "I am writing an email."
        case .chat: "I am writing a chat message."
        case .document: "I am writing a document."
        case .search: "I am typing a search query."
        case .terminal: "I am typing in a terminal."
        case .code: "I am writing code."
        case .form: "I am filling in a form."
        case .aiPrompt: "I am writing a prompt for an AI assistant."
        case .unknown: nil
        }
    }

    /// Date and time rounded down to 15 minutes, so the line changes rarely.
    static func dateLine(_ now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: now)
        let hour = parts.hour ?? 0
        let minute = (parts.minute ?? 0) / 15 * 15
        let weekday = weekdays[((parts.weekday ?? 1) - 1 + 7) % 7]
        let month = months[((parts.month ?? 1) - 1 + 12) % 12]
        let clockHour = hour % 12 == 0 ? 12 : hour % 12
        let clockMinute = minute < 10 ? "0\(minute)" : "\(minute)"
        let period = hour < 12 ? "AM" : "PM"
        return "It is \(weekday), \(month) \(parts.day ?? 1), \(parts.year ?? 2000), around \(clockHour):\(clockMinute) \(period)."
    }

    private static func singleLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > valueLimit else { return collapsed }
        return collapsed.prefix(valueLimit - 1) + SectionFitter.marker
    }

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let months = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
}

enum TemporalCues {
    static let tailLength = 200

    static func isRelevant(fieldKind: FieldKind, textBefore: String, language: String?) -> Bool {
        if fieldKind == .email || fieldKind == .chat { return true }
        return mentionsTime(String(textBefore.suffix(tailLength)), language: language)
    }

    static func mentionsTime(_ text: String, language: String?) -> Bool {
        let tokens = tokenize(TextFolding.fold(text))
        let vocabulary = vocabulary(for: language)
        for (offset, token) in tokens.enumerated() {
            if vocabulary.words.contains(token) || vocabulary.words.contains(withoutProclitic(token)) { return true }
            if isClockTime(token) { return true }
            guard offset + 1 < tokens.count else { continue }
            let next = tokens[offset + 1]
            if vocabulary.phrases.contains(token + " " + next) { return true }
            if isHour(token), clockSuffixes.contains(next) { return true }
        }
        return false
    }

    private struct Vocabulary {
        var words: Set<String> = []
        var phrases: Set<String> = []
    }

    private static func vocabulary(for language: String?) -> Vocabulary {
        let code = language.map { String($0.prefix { $0 != "-" }) }
        guard let code, code != "en", let own = lexicons[code], let english = lexicons["en"] else {
            return combined
        }
        return Vocabulary(words: english.words.union(own.words), phrases: english.phrases.union(own.phrases))
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split { !($0.isWordCharacter || $0 == ":") }
            .map { String($0.replacingOccurrences(of: "\u{2019}", with: "'")).trimmingCharacters(in: edgePunctuation) }
            .filter { !$0.isEmpty }
    }

    private static func withoutProclitic(_ token: String) -> String {
        guard token.count > 3, let first = token.first, arabicProclitics.contains(first) else { return token }
        return String(token.dropFirst())
    }

    private static func isHour(_ token: String) -> Bool {
        (1...2).contains(token.count) && token.allSatisfy { $0.wholeNumberValue != nil }
    }

    private static func isClockTime(_ token: String) -> Bool {
        var rest = Substring(token)
        let hour = rest.prefix { $0.wholeNumberValue != nil }
        guard (1...2).contains(hour.count) else { return false }
        rest = rest.dropFirst(hour.count)
        var isTime = false
        if rest.first == ":" {
            let minutes = rest.dropFirst().prefix { $0.wholeNumberValue != nil }
            guard minutes.count == 2 else { return false }
            rest = rest.dropFirst(3)
            isTime = true
        }
        if !rest.isEmpty {
            guard let suffix = clockSuffixes.first(where: { rest.hasPrefix($0) }) else { return false }
            rest = rest.dropFirst(suffix.count)
            if suffix == "h" {
                let minutes = rest.prefix { $0.wholeNumberValue != nil }
                guard minutes.isEmpty || minutes.count == 2 else { return false }
                rest = rest.dropFirst(minutes.count)
            }
            isTime = true
        }
        return isTime && rest.isEmpty
    }

    private static let edgePunctuation = CharacterSet(charactersIn: "':")
    private static let clockSuffixes = ["am", "pm", "uhr", "h"]
    private static let arabicProclitics: Set<Character> = ["و", "ف", "ب", "ل"]

    private static let lexicons: [String: Vocabulary] = {
        let raw: [String: (words: [String], phrases: [String])] = [
            "en": (
                ["today", "tomorrow", "tmrw", "tonight", "yesterday", "weekend", "noon", "midnight",
                 "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                 "january", "february", "march", "april", "june", "july", "august",
                 "september", "october", "november", "december"],
                ["next week", "this week", "last week", "next month", "this month", "last month",
                 "next year", "this morning", "this afternoon", "this evening"]
            ),
            "es": (
                ["hoy", "mañana", "ayer", "anoche", "finde", "mediodía", "medianoche",
                 "lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo",
                 "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
                 "septiembre", "setiembre", "octubre", "noviembre", "diciembre"],
                ["esta noche", "esta semana", "próxima semana", "semana pasada", "este mes", "próximo mes"]
            ),
            "de": (
                ["heute", "morgen", "gestern", "übermorgen", "vorgestern", "wochenende", "mittag", "mitternacht",
                 "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonnabend", "sonntag",
                 "januar", "februar", "märz", "april", "mai", "juni", "juli", "august",
                 "september", "oktober", "november", "dezember"],
                ["nächste woche", "diese woche", "letzte woche", "nächsten monat", "diesen monat"]
            ),
            "fr": (
                ["aujourd'hui", "demain", "hier", "midi", "minuit", "weekend",
                 "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
                 "janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
                 "septembre", "octobre", "novembre", "décembre"],
                ["ce soir", "ce matin", "cette semaine", "semaine prochaine", "semaine dernière",
                 "mois prochain", "week end"]
            ),
            "ar": (
                ["اليوم", "غدا", "غداً", "بكرة", "بكره", "أمس", "الأمس", "البارحة", "الليلة", "الساعة", "الظهر",
                 "الاثنين", "الإثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت", "الأحد",
                 "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس",
                 "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"],
                ["الأسبوع القادم", "الأسبوع الجاي", "هذا الأسبوع", "الأسبوع الماضي", "الشهر القادم", "هذا المساء"]
            ),
        ]
        return raw.mapValues { entry in
            Vocabulary(
                words: Set(entry.words.map(TextFolding.fold)),
                phrases: Set(entry.phrases.map(TextFolding.fold))
            )
        }
    }()

    private static let combined = lexicons.values.reduce(into: Vocabulary()) { result, vocabulary in
        result.words.formUnion(vocabulary.words)
        result.phrases.formUnion(vocabulary.phrases)
    }
}
