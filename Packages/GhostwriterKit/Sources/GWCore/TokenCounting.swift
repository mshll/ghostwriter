public protocol TokenCounting: Sendable {
    func countTokens(_ text: String) -> Int
}
