import Foundation

public struct Snippet: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var body: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), trigger: String, body: String, isEnabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.body = body
        self.isEnabled = isEnabled
    }
}
