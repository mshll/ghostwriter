public enum InsertionMode: Sendable, Codable, Hashable {
    case keystrokes(chunkSize: Int)
    case paste

    public static let standard = InsertionMode.keystrokes(chunkSize: 20)
}

public struct AppRule: Sendable, Codable, Hashable, Identifiable {
    public var bundleID: String
    public var completionsEnabled: Bool?
    public var midLineEnabled: Bool?
    public var recordWriting: Bool?
    public var tabAcceptEnabled: Bool?
    public var typoFixesEnabled: Bool?
    public var codeEditorCompletions: Bool?
    public var screenContextEnabled: Bool?
    public var needsEnhancedUserInterface: Bool?
    public var insertionMode: InsertionMode?
    public var customInstructions: String?

    public var id: String { bundleID }

    public init(
        bundleID: String,
        completionsEnabled: Bool? = nil,
        midLineEnabled: Bool? = nil,
        recordWriting: Bool? = nil,
        tabAcceptEnabled: Bool? = nil,
        typoFixesEnabled: Bool? = nil,
        codeEditorCompletions: Bool? = nil,
        screenContextEnabled: Bool? = nil,
        needsEnhancedUserInterface: Bool? = nil,
        insertionMode: InsertionMode? = nil,
        customInstructions: String? = nil
    ) {
        self.bundleID = bundleID
        self.completionsEnabled = completionsEnabled
        self.midLineEnabled = midLineEnabled
        self.recordWriting = recordWriting
        self.tabAcceptEnabled = tabAcceptEnabled
        self.typoFixesEnabled = typoFixesEnabled
        self.codeEditorCompletions = codeEditorCompletions
        self.screenContextEnabled = screenContextEnabled
        self.needsEnhancedUserInterface = needsEnhancedUserInterface
        self.insertionMode = insertionMode
        self.customInstructions = customInstructions
    }

    public func merged(with override: AppRule?) -> AppRule {
        guard let override else { return self }
        var result = self
        result.completionsEnabled = override.completionsEnabled ?? completionsEnabled
        result.midLineEnabled = override.midLineEnabled ?? midLineEnabled
        result.recordWriting = override.recordWriting ?? recordWriting
        result.tabAcceptEnabled = override.tabAcceptEnabled ?? tabAcceptEnabled
        result.typoFixesEnabled = override.typoFixesEnabled ?? typoFixesEnabled
        result.codeEditorCompletions = override.codeEditorCompletions ?? codeEditorCompletions
        result.screenContextEnabled = override.screenContextEnabled ?? screenContextEnabled
        result.needsEnhancedUserInterface = override.needsEnhancedUserInterface ?? needsEnhancedUserInterface
        result.insertionMode = override.insertionMode ?? insertionMode
        result.customInstructions = override.customInstructions ?? customInstructions
        return result
    }
}
