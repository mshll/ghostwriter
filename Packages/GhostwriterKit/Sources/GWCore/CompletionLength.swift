public enum CompletionLength: Int, Sendable, Codable, CaseIterable, Identifiable {
    case short = 2
    case medium = 4
    case long = 7
    case veryLong = 10
    case ultraLong = 15

    public var id: Int { rawValue }
    public var maxWords: Int { rawValue }

    public var title: String {
        switch self {
        case .short: "Short"
        case .medium: "Medium"
        case .long: "Long"
        case .veryLong: "Very long"
        case .ultraLong: "Ultra long"
        }
    }
}
