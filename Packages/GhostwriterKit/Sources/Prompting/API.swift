import Foundation
import GWCore

public enum PromptMode: Sendable, Hashable { case inline, draft }

public struct PromptContext: Sendable, Hashable {
    public var instructions: String?
    public var userName: String?
    public var appName: String
    public var windowTitle: String?
    public var domain: String?
    public var fieldKind: FieldKind
    public var fieldLabel: String?
    public var now: Date
    public var examples: [String]
    public var clipboard: String?
    public var screenText: String?
    public var textBefore: String
    public var textAfter: String
    public var mode: PromptMode
    /// Keeps the date line even when no time word is near the caret any more. Set once the line has appeared in
    /// a focus session: dropping it changes the prompt early and every token after it is decoded again.
    public var keepsDate: Bool

    public init(
        instructions: String? = nil, userName: String? = nil, appName: String, windowTitle: String? = nil,
        domain: String? = nil, fieldKind: FieldKind = .unknown, fieldLabel: String? = nil, now: Date = .now,
        examples: [String] = [], clipboard: String? = nil, screenText: String? = nil,
        textBefore: String, textAfter: String = "", mode: PromptMode = .inline, keepsDate: Bool = false
    ) {
        self.instructions = instructions
        self.userName = userName
        self.appName = appName
        self.windowTitle = windowTitle
        self.domain = domain
        self.fieldKind = fieldKind
        self.fieldLabel = fieldLabel
        self.now = now
        self.examples = examples
        self.clipboard = clipboard
        self.screenText = screenText
        self.textBefore = textBefore
        self.textAfter = textAfter
        self.mode = mode
        self.keepsDate = keepsDate
    }
}

/// Token caps per section. `before` and `after` are reserved out of `total` first, so the
/// context sections keep the same size while the user types; `instructions` sits outside `total`.
public struct PromptBudgets: Sendable, Hashable {
    public var screen = 600
    public var clipboard = 300
    public var examples = 400
    public var before = 350
    public var after = 200
    public var instructions = 1000
    public var step = 32
    public var total = 1700

    public init() {}
}

public struct BuiltPrompt: Sendable, Hashable {
    public var text: String
    public var partialWord: String
    public var language: String?
    public var includesDate = false

    public static let stopStrings: [String] = (PromptText.labels + [PromptText.preamble]).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    } + [PromptText.separatorStop, PromptText.preambleTail] + EnvironmentLines.stopStarts
}
