import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GWCore
import os

private let log = Logger.gw("input")

@MainActor
public final class KeyMonitor {
    public var onKey: ((KeyEvent) -> Void)?
    public var onPointer: (() -> Void)?

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var pointerMonitor: Any?

    public init() {}

    isolated deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Key tap creation failed: no permission to listen to key events")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            log.error("Key tap run loop source creation failed")
            CFMachPortInvalidate(tap)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        tapSource = source
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onPointer?() }
        }
        return true
    }

    public func stop() {
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
        }
        pointerMonitor = nil
    }

    fileprivate func handle(_ type: CGEventType, key: KeyEvent?) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            log.notice("Key tap disabled by the system (type \(type.rawValue)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            if let key { onKey?(key) }
        }
    }
}

private func keyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<KeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let key = type == .keyDown ? KeyEvent(event) : nil
        MainActor.assumeIsolated { monitor.handle(type, key: key) }
    }
    return Unmanaged.passUnretained(event)
}

extension KeyEvent {
    init?(_ event: CGEvent) {
        guard event.getIntegerValueField(.eventSourceUserData) != EventMarker.userData else { return nil }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        var units = [UniChar](repeating: 0, count: 8)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        let characters = String(utf16CodeUnits: units, count: min(length, units.count))
        let modifiers = Self.modifiers(from: event.flags)
        self.init(
            kind: Self.kind(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers), characters: characters),
            keyCode: keyCode,
            modifiers: modifiers,
            characters: characters
        )
    }

    /// The device-independent bits of `CGEventFlags` share their positions with `NSEvent.ModifierFlags`.
    static func modifiers(from flags: CGEventFlags) -> UInt {
        UInt(flags.rawValue) & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue
    }

    static let navigationKeyCodes: Set<UInt16> = Set([
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
    ].map { UInt16($0) })

    static func kind(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String) -> Kind {
        if navigationKeyCodes.contains(keyCode) { return .navigation }
        if !modifiers.isDisjoint(with: [.command, .control]) { return .shortcut }
        switch Int(keyCode) {
        case kVK_Delete: return .deleteBackward
        case kVK_ForwardDelete: return .deleteForward
        case kVK_Return, kVK_ANSI_KeypadEnter: return .returnKey
        case kVK_Tab: return .tab
        case kVK_Escape: return .escape
        default: return isPrintable(characters) ? .character : .other
        }
    }

    private static func isPrintable(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy { scalar in
            scalar.properties.generalCategory != .control && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}
