import SwiftUI

/// Raw values are the `ghostwriter://settings/<pane>` argument.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, suggestions, shortcuts
    case model, context, personalization
    case apps, snippets, selectionActions
    case statistics, privacy, updates
    case about

    var id: Self { self }

    /// About is not here; the sidebar pins it to its foot.
    static let groups: [[SettingsPane]] = [
        [.general, .suggestions, .shortcuts],
        [.model, .context, .personalization],
        [.apps, .snippets, .selectionActions],
        [.statistics, .privacy, .updates],
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .suggestions: "Suggestions"
        case .shortcuts: "Shortcuts"
        case .model: "Model"
        case .context: "Context"
        case .personalization: "Personalization"
        case .apps: "Apps"
        case .snippets: "Snippets"
        case .selectionActions: "Selection Actions"
        case .statistics: "Statistics"
        case .privacy: "Privacy & Data"
        case .updates: "Updates"
        case .about: "About Ghostwriter"
        }
    }

    var headerTitle: String {
        self == .about ? "Ghostwriter" : title
    }

    var summary: String {
        switch self {
        case .general: "How Ghostwriter starts, and what it needs from macOS."
        case .suggestions: "When suggestions appear, how long they run, and how you accept them."
        case .shortcuts: "Keys that accept a suggestion, and shortcuts that work in any app."
        case .model: "The model on this Mac that writes your suggestions."
        case .context: "What Ghostwriter may read so a suggestion fits what you\u{2019}re writing."
        case .personalization: "Your words, your name, and how you like to write."
        case .apps: "Change how Ghostwriter behaves in one app."
        case .snippets: "Short triggers that expand into longer text."
        case .selectionActions: "Rewrite, fix, shorten or translate the text you select."
        case .statistics: "How much Ghostwriter wrote for you."
        case .privacy: "Everything stays on this Mac. Here is what Ghostwriter keeps, and how to remove it."
        case .updates: "How Ghostwriter finds and installs new versions."
        case .about: "Autocomplete for every app, on this Mac."
        }
    }

    var symbol: String? {
        switch self {
        case .general: "gearshape.fill"
        case .suggestions: "text.cursor"
        case .shortcuts: "keyboard.fill"
        case .model: "cpu.fill"
        case .context: "text.viewfinder"
        case .personalization: "person.fill"
        case .apps: "square.grid.2x2.fill"
        case .snippets: "text.badge.plus"
        case .selectionActions: "wand.and.stars"
        case .statistics: "chart.bar.fill"
        case .privacy: "hand.raised.fill"
        case .updates: "arrow.trianglehead.2.clockwise"
        case .about: nil
        }
    }
}

extension SettingsPane {
    var rows: [SettingText] {
        switch self {
        case .general: GeneralSetting.allCases.map(\.text)
        case .suggestions: SuggestionsSetting.allCases.map(\.text)
        case .shortcuts: ShortcutsSetting.allCases.map(\.text)
        case .model: ModelSetting.allCases.map(\.text)
        case .context: ContextSetting.allCases.map(\.text)
        case .personalization: PersonalizationSetting.allCases.map(\.text)
        case .apps: AppsSetting.allCases.map(\.text)
        case .snippets: SnippetsSetting.allCases.map(\.text)
        case .selectionActions: SelectionActionsSetting.allCases.map(\.text)
        case .statistics: StatisticsSetting.allCases.map(\.text)
        case .privacy: PrivacySetting.allCases.map(\.text)
        case .updates: UpdatesSetting.allCases.map(\.text)
        case .about: AboutSetting.allCases.map(\.text)
        }
    }

    func matches(_ query: String) -> [String] {
        rows
            .filter { row in
                Self.text(([row.title, row.subtitle].compactMap(\.self) + row.keywords).joined(separator: " "), contains: query)
            }
            .map(\.title)
    }

    func isFound(by query: String) -> Bool {
        Self.text(title, contains: query) || !matches(query).isEmpty
    }

    private static func text(_ text: String, contains query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
