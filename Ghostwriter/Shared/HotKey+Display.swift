import AppKit
import Carbon.HIToolbox
import Input

extension HotKey {
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    var displayName: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyName
    }

    var keyName: String {
        if let special = Self.specialKeyNames[Int(keyCode)] { return special }
        return Self.character(for: UInt16(truncatingIfNeeded: keyCode))?.uppercased() ?? "Key \(keyCode)"
    }

    var isWritingKey: Bool {
        if modifiers & UInt32(cmdKey | controlKey) != 0 { return false }
        if keyCode == Self.tabKeyCode || keyCode == UInt32(KeyboardLayout.keyAboveTab) { return false }
        if [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space].contains(Int(keyCode)) { return true }
        return Self.specialKeyNames[Int(keyCode)] == nil
    }

    static func acceptKeyWarning(for key: HotKey, otherKey: HotKey) -> String? {
        if key == otherKey {
            return "Both accept actions use \(key.displayName). Choose a different key for one of them."
        }
        if key.isWritingKey {
            let name = key.displayName
            return "\(name) is a key you type with. While a suggestion is visible, pressing it accepts the suggestion instead of typing \(name). Tab or the key above Tab work best."
        }
        return nil
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Tab: "Tab", kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter", kVK_Space: "Space",
        kVK_Escape: "Esc", kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
