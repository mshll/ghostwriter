import AppKit
import Carbon.HIToolbox

public enum InputSource {
    @MainActor
    public static var isInputMethodActive: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
        else { return false }
        return withExtendedLifetime(source) {
            Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String != kTISTypeKeyboardLayout as String
        }
    }
}

public enum KeyboardLayout {
    public static var keyAboveTab: UInt16 {
        KBGetLayoutType(Int16(LMGetKbdType())) == PhysicalKeyboardLayoutType(kKeyboardISO) ? 10 : 50
    }

    @MainActor
    static func keyCode(typing character: String, carbonModifiers: UInt32 = 0) -> UInt16? {
        withCurrentLayout { layout in
            (0..<128).map(UInt16.init).first { translate($0, carbonModifiers: carbonModifiers, layout: layout) == character }
        } ?? nil
    }

    @MainActor
    static func characters(for keyCode: UInt16) -> String? {
        withCurrentLayout { translate(keyCode, carbonModifiers: 0, layout: $0) } ?? nil
    }

    @MainActor
    private static func withCurrentLayout<T>(_ body: (UnsafePointer<UCKeyboardLayout>) -> T) -> T? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return withExtendedLifetime(source) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1, body)
        }
    }

    private static func translate(
        _ keyCode: UInt16,
        carbonModifiers: UInt32,
        layout: UnsafePointer<UCKeyboardLayout>
    ) -> String? {
        var deadKeyState: UInt32 = 0
        var units = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            (carbonModifiers >> 8) & 0xFF,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            units.count,
            &length,
            &units
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: units, count: length)
    }
}

extension HotKey {
    public static let tab = HotKey(keyCode: UInt32(kVK_Tab))
    public static let optionTab = HotKey(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey))
    public static let escape = HotKey(keyCode: UInt32(kVK_Escape))
    public static let deleteBackward = HotKey(keyCode: UInt32(kVK_Delete))

    public static var keyAboveTab: HotKey {
        HotKey(keyCode: UInt32(KeyboardLayout.keyAboveTab))
    }

    private static let digitKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    public static func digit(_ number: Int) -> HotKey? {
        guard (1...9).contains(number) else { return nil }
        return HotKey(keyCode: UInt32(digitKeyCodes[number - 1]))
    }

    private static let modifierPairs: [(NSEvent.ModifierFlags, Int)] = [
        (.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey),
    ]

    public init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        let carbon = Self.modifierPairs.reduce(0) { mask, pair in
            modifierFlags.contains(pair.0) ? mask | pair.1 : mask
        }
        self.init(keyCode: UInt32(keyCode), modifiers: UInt32(carbon))
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        Self.modifierPairs.reduce(into: []) { flags, pair in
            if modifiers & UInt32(pair.1) != 0 { flags.insert(pair.0) }
        }
    }

    private static let keyNames: [Int: String] = [
        kVK_Tab: "⇥", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Space: "Space",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    @MainActor
    public var displayString: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = symbols.filter { modifierFlags.contains($0.0) }.map(\.1).joined()
        let code = UInt16(truncatingIfNeeded: keyCode)
        let key = Self.keyNames[Int(keyCode)]
            ?? KeyboardLayout.characters(for: code)?.uppercased()
            ?? "Key \(keyCode)"
        return prefix + key
    }
}
