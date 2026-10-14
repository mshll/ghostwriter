import Darwin
import GWCore

public struct KeyEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case character
        case deleteBackward
        case deleteForward
        case returnKey
        case tab
        case escape
        case navigation
        case shortcut
        case other
    }

    public var kind: Kind
    public var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value.
    public var modifiers: UInt
    public var characters: String

    public init(kind: Kind, keyCode: UInt16, modifiers: UInt, characters: String) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.characters = characters
    }
}

public struct HotKey: Sendable, Hashable, Codable {
    public var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
