import AppKit
import Carbon.HIToolbox
import GWCore
import os

private let log = Logger.gw("input")
private let hotKeySignature: OSType = 0x6777_686B

/// Carbon hot keys. A registered key is swallowed system-wide, so register only while it has a job.
@MainActor
public final class HotKeyCenter {
    private struct Registration {
        var id: UInt32
        var ref: EventHotKeyRef
        var action: @MainActor () -> Void
    }

    /// A press can reach the handler after its key was unregistered; within this time it is passed on to the app.
    private static let staleFireWindow: Duration = .seconds(1)
    private static var lastID: UInt32 = 0
    private var registrations: [HotKey: Registration] = [:]
    private var unregistered: [UInt32: (hotKey: HotKey, at: ContinuousClock.Instant)] = [:]
    private var handlerRef: EventHandlerRef?

    public init() {}

    isolated deinit {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    @discardableResult
    public func register(_ hotKey: HotKey, action: @escaping @MainActor () -> Void) -> Bool {
        if registrations[hotKey] != nil {
            registrations[hotKey]?.action = action
            return true
        }
        guard installHandlerIfNeeded() else { return false }
        Self.lastID &+= 1
        let id = EventHotKeyID(signature: hotKeySignature, id: Self.lastID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey failed (keyCode \(hotKey.keyCode), modifiers \(hotKey.modifiers)): \(status)")
            return false
        }
        registrations[hotKey] = Registration(id: id.id, ref: ref, action: action)
        return true
    }

    public func unregister(_ hotKey: HotKey) {
        guard let registration = registrations.removeValue(forKey: hotKey) else { return }
        let status = UnregisterEventHotKey(registration.ref)
        if status != noErr {
            log.error("UnregisterEventHotKey failed (keyCode \(hotKey.keyCode)): \(status)")
        }
        let now = ContinuousClock.now
        unregistered = unregistered.filter { now - $0.value.at <= Self.staleFireWindow }
        unregistered[registration.id] = (hotKey, now)
    }

    public func unregisterAll() {
        for hotKey in Array(registrations.keys) {
            unregister(hotKey)
        }
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            log.error("InstallEventHandler for hot keys failed: \(status)")
            return false
        }
        return true
    }

    fileprivate func fire(id: UInt32) -> Bool {
        if let action = registrations.values.first(where: { $0.id == id })?.action {
            action()
            return true
        }
        guard let stale = unregistered.removeValue(forKey: id), ContinuousClock.now - stale.at <= Self.staleFireWindow,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return false }
        log.debug("Hot key \(stale.hotKey.keyCode) fired after it was unregistered; passing it on")
        let flags = CGEventFlags(rawValue: UInt64(stale.hotKey.modifierFlags.rawValue))
        TextInserter.postKeyPress(keyCode: Int(stale.hotKey.keyCode), flags: flags, to: pid)
        return true
    }
}

private func hotKeyHandler(
    _ call: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    let handled = MainActor.assumeIsolated { center.fire(id: id) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
