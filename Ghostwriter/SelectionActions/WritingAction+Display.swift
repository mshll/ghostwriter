import Actions

extension WritingAction {
    var title: String {
        switch self {
        case .rephrase: "Rephrase"
        case .fixGrammar: "Fix Grammar"
        case .shorten: "Shorten"
        case .expand: "Expand"
        case .formal: "Make Formal"
        case .casual: "Make Casual"
        case .translate: "Translate"
        }
    }

    var symbol: String {
        switch self {
        case .rephrase: "arrow.triangle.2.circlepath"
        case .fixGrammar: "text.badge.checkmark"
        case .shorten: "arrow.down.right.and.arrow.up.left"
        case .expand: "arrow.up.left.and.arrow.down.right"
        case .formal: "briefcase"
        case .casual: "face.smiling"
        case .translate: "globe"
        }
    }

    static let translationLanguages = [
        "Arabic", "Chinese", "Danish", "Dutch", "English", "French", "German", "Italian", "Japanese",
        "Korean", "Norwegian", "Portuguese", "Spanish", "Swedish", "Turkish", "Vietnamese",
    ]
}
