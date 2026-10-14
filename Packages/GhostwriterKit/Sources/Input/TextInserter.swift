import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GWCore
import os

private let log = Logger.gw("input")

/// Types text into an app with synthetic key events posted to its pid. Every event carries `EventMarker.userData`.
public enum TextInserter {
    static let eventGap: Duration = .milliseconds(1)

    /// Keystroke mode pastes instead while an input method is active: it would compose the typed characters.
    public static func insert(_ text: String, into pid: pid_t, mode: InsertionMode) async {
        guard !text.isEmpty else { return }
        switch mode {
        case .keystrokes(let chunkSize):
            if await InputSource.isInputMethodActive {
                await PasteInserter.shared.paste(text, into: pid)
            } else {
                await type(text, into: pid, chunkSize: chunkSize)
            }
        case .paste:
            await PasteInserter.shared.paste(text, into: pid)
        }
    }

    public static func deleteBackward(count: Int, in pid: pid_t) async {
        guard count > 0, let source = markedSource() else { return }
        for _ in 0..<count {
            for keyDown in [true, false] {
                post(keyCode: kVK_Delete, keyDown: keyDown, flags: [], source: source, to: pid)
                await pause()
            }
        }
    }

    public static func moveCaretLeft(count: Int, in pid: pid_t) async {
        guard count > 0, let source = markedSource() else { return }
        for _ in 0..<count {
            for keyDown in [true, false] {
                post(keyCode: kVK_LeftArrow, keyDown: keyDown, flags: [], source: source, to: pid)
                await pause()
            }
        }
    }

    /// Keys posted while the user still holds a shortcut's modifiers act as shortcuts: Command-Delete deletes
    /// the whole line. Returns false if the modifiers are still down at the timeout.
    public static func waitForModifierRelease(timeout: Duration = .seconds(3)) async -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = ContinuousClock.now + timeout
        while !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty {
            guard ContinuousClock.now < deadline else { return false }
            await pause(.milliseconds(20))
        }
        return true
    }

    public static func postTab(to pid: pid_t) {
        postKeyPress(keyCode: kVK_Tab, flags: [], to: pid)
    }

    static func chunks(of text: String, limit: Int) -> [String] {
        let limit = max(limit, 1)
        var result: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = character.utf16.count
            if currentUnits > 0, currentUnits + units > limit {
                result.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func type(_ text: String, into pid: pid_t, chunkSize: Int) async {
        guard let source = markedSource() else { return }
        for chunk in chunks(of: text, limit: chunkSize) {
            let units = Array(chunk.utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Space), keyDown: keyDown) else {
                    log.error("Could not create a key event; insertion stopped")
                    return
                }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.setIntegerValueField(.eventSourceUserData, value: EventMarker.userData)
                event.postToPid(pid)
                await pause()
            }
        }
    }

    static func postCommandV(to pid: pid_t, keyCode: UInt16) {
        postKeyPress(keyCode: Int(keyCode), flags: .maskCommand, to: pid)
    }

    static func postKeyPress(keyCode: Int, flags: CGEventFlags, to pid: pid_t) {
        guard let source = markedSource() else { return }
        post(keyCode: keyCode, keyDown: true, flags: flags, source: source, to: pid)
        post(keyCode: keyCode, keyDown: false, flags: flags, source: source, to: pid)
    }

    private static func markedSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            log.error("Could not create an event source")
            return nil
        }
        source.userData = EventMarker.userData
        return source
    }

    private static func post(keyCode: Int, keyDown: Bool, flags: CGEventFlags, source: CGEventSource, to pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else {
            log.error("Could not create a key event for key code \(keyCode)")
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: EventMarker.userData)
        event.postToPid(pid)
    }

    static func pause(_ duration: Duration = eventGap) async {
        do {
            try await Task.sleep(for: duration, tolerance: .zero)
        } catch {
            log.debug("Insertion task cancelled; posting the remaining events without delay")
        }
    }
}

@MainActor
final class PasteInserter {
    static let shared = PasteInserter()

    private static let pasteDelay: Duration = .milliseconds(10)
    /// Web apps may read the pasteboard well after Command-V arrives.
    private static let restoreDelay: Duration = .milliseconds(1_500)
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    private static let fallbackKeyCodeV: UInt16 = 9

    private var savedItems: [[(NSPasteboard.PasteboardType, Data)]]?
    private var restoreTask: Task<Void, Never>?
    private var pastedChangeCount = 0

    func paste(_ text: String, into pid: pid_t) async {
        let pasteboard = NSPasteboard.general
        restoreTask?.cancel()
        restoreTask = nil
        if savedItems == nil || pasteboard.changeCount != pastedChangeCount {
            savedItems = Self.snapshot(of: pasteboard)
        }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.concealedType)
        item.setString(AppPaths.bundleID, forType: Self.sourceType)
        pasteboard.writeObjects([item])
        pastedChangeCount = pasteboard.changeCount

        await TextInserter.pause(Self.pasteDelay)
        let keyCode = KeyboardLayout.keyCode(typing: "v", carbonModifiers: UInt32(cmdKey)) ?? Self.fallbackKeyCodeV
        TextInserter.postCommandV(to: pid, keyCode: keyCode)

        restoreTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.restoreDelay)
            } catch {
                return
            }
            self?.restore()
        }
    }

    private func restore() {
        defer {
            savedItems = nil
            restoreTask = nil
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == pastedChangeCount else {
            log.notice("Pasteboard changed after the paste; the previous contents are not restored")
            return
        }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard let savedItems, !savedItems.isEmpty else { return }
        let items = savedItems.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }
}
