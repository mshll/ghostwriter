import CoreGraphics
import Foundation

public struct FieldID: Sendable, Hashable {
    public var pid: pid_t
    public var elementHash: UInt

    public init(pid: pid_t, elementHash: UInt) {
        self.pid = pid
        self.elementHash = elementHash
    }
}

public enum FieldKind: String, Sendable, Codable, CaseIterable {
    case email, chat, document, search, terminal, code, form, aiPrompt, unknown
}

public enum WritingDirection: Sendable, Hashable {
    case leftToRight, rightToLeft
}

public struct RGBAColor: Sendable, Hashable, Codable {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct FieldStyle: Sendable, Hashable {
    public var fontName: String?
    public var fontSize: Double?
    public var textColor: RGBAColor?
    /// Set when the app reports the weight or slant apart from the font name.
    public var isBold: Bool
    public var isItalic: Bool

    public init(
        fontName: String? = nil,
        fontSize: Double? = nil,
        textColor: RGBAColor? = nil,
        isBold: Bool = false,
        isItalic: Bool = false
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.textColor = textColor
        self.isBold = isBold
        self.isItalic = isItalic
    }
}

/// Geometry uses global screen coordinates with a top-left origin (the AX convention).
public struct FieldSnapshot: Sendable, Hashable {
    public var id: FieldID
    public var app: AppIdentity
    public var textBefore: String
    public var textAfter: String
    public var selectedText: String
    public var caretRect: CGRect
    public var fieldFrame: CGRect
    public var style: FieldStyle
    public var kind: FieldKind
    public var direction: WritingDirection
    public var label: String?
    public var windowTitle: String?
    public var url: URL?
    public var language: String?

    public init(
        id: FieldID,
        app: AppIdentity,
        textBefore: String,
        textAfter: String,
        selectedText: String = "",
        caretRect: CGRect,
        fieldFrame: CGRect,
        style: FieldStyle = FieldStyle(),
        kind: FieldKind = .unknown,
        direction: WritingDirection = .leftToRight,
        label: String? = nil,
        windowTitle: String? = nil,
        url: URL? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.app = app
        self.textBefore = textBefore
        self.textAfter = textAfter
        self.selectedText = selectedText
        self.caretRect = caretRect
        self.fieldFrame = fieldFrame
        self.style = style
        self.kind = kind
        self.direction = direction
        self.label = label
        self.windowTitle = windowTitle
        self.url = url
        self.language = language
    }

    public var isMidLine: Bool {
        guard let next = textAfter.first else { return false }
        return !next.isNewline
    }
}
