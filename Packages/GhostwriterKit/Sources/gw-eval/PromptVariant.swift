import Foundation

/// Rewrites of the app's prompt for experiments. They edit the built text, so they follow the app's wording.
enum PromptVariant: String {
    case standard
    case bare
    case noPreamble = "no-preamble"
    case noEnvironment = "no-environment"

    private static let preamble =
        "I am typing on my Mac. My text comes last; before it is some context, which may or may not be relevant.\n\n"
    private static let typingLabel = "What I am writing"
    private static let environmentPrefixes = ["My name is ", "I am typing in ", "The window is titled ", "The website is ", "I am writing ",
                                              "I am typing ", "I am filling ", "The field is labeled ", "It is "]

    func apply(to prompt: String, before: String) -> String {
        switch self {
        case .standard: prompt
        case .bare: before
        case .noPreamble: String(prompt.dropFirst(prompt.hasPrefix(Self.preamble) ? Self.preamble.count : 0))
        case .noEnvironment: Self.withoutEnvironment(prompt)
        }
    }

    private static func withoutEnvironment(_ prompt: String) -> String {
        guard let label = prompt.range(of: typingLabel, options: .backwards) else { return prompt }
        let blocks = prompt[..<label.lowerBound].components(separatedBy: "\n\n").filter { block in
            block.isEmpty || block + "\n\n" == preamble
                || !block.split(separator: "\n").allSatisfy { line in environmentPrefixes.contains { line.hasPrefix($0) } }
        }
        return blocks.joined(separator: "\n\n") + prompt[label.lowerBound...]
    }
}
