import AppKit
import ApplicationServices
import Carbon.HIToolbox
import GWCore
import Input
import Overlay

let usage = """
    usage: gw-inputprobe <command> [options]
      overlay [--multiline] [--rtl] [--picker [--click N]] [--seconds N] [text]
                                  ghost text at the focused caret (read via AX); --click posts a marked click on picker row N
      insert [--paste] [--chunk N] <text>
                                  insert into the focused field after 2 s
      delete <count>              press Delete <count> times after 2 s
      tab                         post a real Tab after 2 s
      monitor [--seconds N] [--selftest]
                                  print key events (selftest: marked events must be ignored)
      hotkey [--seconds N] [--selftest]
                                  register Tab and print presses (selftest: register, unregister, bypass)
    options:
      --app <bundle id>           frontmost app required before any synthetic event (default com.apple.TextEdit)
      --document <path>           file open in the focused window, also required before any synthetic event
    """

struct Options {
    var command = ""
    var words: [String] = []
    var app = "com.apple.TextEdit"
    var document: String?
    var seconds: Double = 5
    var multiline = false
    var rtl = false
    var picker = false
    var click: Int?
    var paste = false
    var chunk = InsertionMode.standard
    var selftest = false

    init(_ arguments: [String]) {
        var rest = arguments[...]
        command = rest.popFirst() ?? ""
        while let argument = rest.popFirst() {
            switch argument {
            case "--app": app = rest.popFirst() ?? app
            case "--document": document = rest.popFirst()
            case "--seconds": seconds = rest.popFirst().flatMap(Double.init) ?? seconds
            case "--multiline": multiline = true
            case "--rtl": rtl = true
            case "--picker": picker = true
            case "--click": click = rest.popFirst().flatMap(Int.init)
            case "--paste": paste = true
            case "--chunk": chunk = .keystrokes(chunkSize: rest.popFirst().flatMap(Int.init) ?? 20)
            case "--selftest": selftest = true
            default: words.append(argument)
            }
        }
        if command == "monitor" || command == "hotkey", !arguments.contains("--seconds") { seconds = 10 }
    }

    var text: String { words.joined(separator: " ") }
    var insertionMode: InsertionMode { paste ? .paste : chunk }
}

// MARK: Minimal AX access (the probe does not depend on Capture)

struct FocusedField {
    let element: AXUIElement
    let pid: pid_t
    let value: String
    let selection: CFRange
    let snapshot: FieldSnapshot
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func parameterized(_ element: AXUIElement, _ name: String, range: CFRange) -> CFTypeRef? {
    var range = range
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var value: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
}

func axStruct<T: BitwiseCopyable>(_ ref: CFTypeRef?, _ type: AXValueType, _ initial: T) -> T? {
    guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    var value = initial
    return AXValueGetValue(unsafeDowncast(ref, to: AXValue.self), type, &value) ? value : nil
}

/// Character bounds first: TextEdit answers zero-length ranges with a rect one line too high.
func caretRect(_ element: AXUIElement, location: Int, text: NSString, rightToLeft: Bool) -> CGRect? {
    func bounds(_ location: Int, _ length: Int) -> CGRect? {
        guard let rect = axStruct(
            parameterized(element, kAXBoundsForRangeParameterizedAttribute, range: CFRange(location: location, length: length)),
            .cgRect,
            CGRect.zero
        ), rect.height > 0 else { return nil }
        return rect
    }
    func isNewline(_ index: Int) -> Bool {
        guard index >= 0, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)) else { return true }
        return Character(scalar).isNewline
    }
    if location > 0, !isNewline(location - 1), let previous = bounds(location - 1, 1) {
        return CGRect(x: rightToLeft ? previous.minX : previous.maxX, y: previous.minY, width: 1, height: previous.height)
    }
    if !isNewline(location), let next = bounds(location, 1) {
        return CGRect(x: rightToLeft ? next.maxX : next.minX, y: next.minY, width: 1, height: next.height)
    }
    return bounds(location, 0).map { CGRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) }
}

func fieldStyle(_ element: AXUIElement, location: Int) -> FieldStyle {
    let range = CFRange(location: max(location - 1, 0), length: 1)
    guard let attributed = parameterized(element, kAXAttributedStringForRangeParameterizedAttribute, range: range) as? NSAttributedString,
          attributed.length > 0
    else { return FieldStyle() }
    let font = attributed.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any]
    var style = FieldStyle(
        fontName: font?["AXFontName"] as? String,
        fontSize: (font?["AXFontSize"] as? NSNumber)?.doubleValue
    )
    if let ref = attributed.attribute(NSAttributedString.Key("AXForegroundColor"), at: 0, effectiveRange: nil) as CFTypeRef?,
       CFGetTypeID(ref) == CGColor.typeID,
       let color = NSColor(cgColor: unsafeDowncast(ref, to: CGColor.self))?.usingColorSpace(.sRGB) {
        style.textColor = RGBAColor(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }
    return style
}

func readFocusedField(rightToLeft: Bool = false) -> FocusedField? {
    let frontmost = NSWorkspace.shared.frontmostApplication.map { AXUIElementCreateApplication($0.processIdentifier) }
    let focused = [frontmost, AXUIElementCreateSystemWide()].lazy.compactMap { owner in
        owner.flatMap { attribute($0, kAXFocusedUIElementAttribute) }
    }.first
    guard let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    let element = unsafeDowncast(ref, to: AXUIElement.self)
    let value = attribute(element, kAXValueAttribute) as? String ?? ""
    let nsValue = value as NSString
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success,
          let selection = axStruct(attribute(element, kAXSelectedTextRangeAttribute), .cfRange, CFRange()),
          let caret = caretRect(element, location: selection.location, text: nsValue, rightToLeft: rightToLeft)
    else { return nil }
    let location = min(selection.location, nsValue.length)
    let position = axStruct(attribute(element, kAXPositionAttribute), .cgPoint, CGPoint.zero) ?? .zero
    let size = axStruct(attribute(element, kAXSizeAttribute), .cgSize, CGSize.zero) ?? .zero
    let app = NSRunningApplication(processIdentifier: pid)
    let snapshot = FieldSnapshot(
        id: FieldID(pid: pid, elementHash: UInt(CFHash(element))),
        app: AppIdentity(bundleID: app?.bundleIdentifier ?? "", name: app?.localizedName ?? "", pid: pid),
        textBefore: nsValue.substring(to: location),
        textAfter: nsValue.substring(from: min(location + selection.length, nsValue.length)),
        caretRect: caret,
        fieldFrame: CGRect(origin: position, size: size),
        style: fieldStyle(element, location: selection.location)
    )
    return FocusedField(element: element, pid: pid, value: value, selection: selection, snapshot: snapshot)
}

// MARK: Helpers

@MainActor
func finish(_ code: Int32 = 0) -> Never {
    fflush(stdout)
    exit(code)
}

func wait(_ seconds: Double) async {
    do {
        try await Task.sleep(for: .seconds(seconds))
    } catch {
        print("wait interrupted: \(error)")
    }
}

func focusedDocumentPath(of pid: pid_t) -> String? {
    guard let ref = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
          CFGetTypeID(ref) == AXUIElementGetTypeID(),
          let document = attribute(unsafeDowncast(ref, to: AXUIElement.self), kAXDocumentAttribute) as? String,
          let url = URL(string: document)
    else { return nil }
    return url.resolvingSymlinksInPath().path
}

@MainActor
func requireFrontmost(_ options: Options) -> NSRunningApplication {
    guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == options.app else {
        print("ABORT: frontmost app is \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"), expected \(options.app)")
        finish(2)
    }
    if let document = options.document {
        let expected = URL(fileURLWithPath: document).resolvingSymlinksInPath().path
        let actual = focusedDocumentPath(of: app.processIdentifier)
        guard actual == expected else {
            print("ABORT: focused document is \(actual ?? "none"), expected \(expected)")
            finish(2)
        }
    }
    return app
}

/// Posts a marked key press through the HID stream, where hot keys and session taps see it.
func postMarkedKeyThroughHID(keyCode: Int, characters: String? = nil) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    source.userData = EventMarker.userData
    for keyDown in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else { continue }
        event.flags = []
        if let characters {
            let units = Array(characters.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        event.setIntegerValueField(.eventSourceUserData, value: EventMarker.userData)
        event.post(tap: .cghidEventTap)
    }
}

func ownWindows() -> [(layer: Int, bounds: CGRect)] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? pid_t) == getpid(),
              let layer = window[kCGWindowLayer as String] as? Int,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        return (layer, rect)
    }
}

func postMarkedClick(at point: CGPoint) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    source.userData = EventMarker.userData
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { continue }
        event.setIntegerValueField(.eventSourceUserData, value: EventMarker.userData)
        event.post(tap: .cghidEventTap)
    }
}

func escaped(_ text: String) -> String {
    text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 ? String($0) : $0.escaped(asASCII: true) }.joined()
}

func milliseconds(_ duration: Duration) -> String {
    String(format: "%.3f ms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
}

// MARK: Commands

@MainActor
func runOverlay(_ options: Options) async {
    if options.document != nil { _ = requireFrontmost(options) }
    guard let field = readFocusedField(rightToLeft: options.rtl) else {
        print("No focused text element with a caret (is the target app frontmost and AX allowed?)")
        finish(1)
    }
    var snapshot = field.snapshot
    if options.rtl { snapshot.direction = .rightToLeft }
    print("app \(snapshot.app.bundleID) caret \(snapshot.caretRect) field \(snapshot.fieldFrame)")
    let regionTop = snapshot.caretRect.minY - 40
    let regionX = options.multiline ? snapshot.fieldFrame.minX : max(snapshot.fieldFrame.minX, snapshot.caretRect.minX - 400)
    print("screenshot-region: \(Int(regionX)),\(Int(regionTop)),\(Int(min(snapshot.fieldFrame.maxX - regionX, 800))),\(Int(snapshot.caretRect.height + 160))")
    print("font \(snapshot.style.fontName ?? "nil") \(snapshot.style.fontSize.map { "\($0)" } ?? "nil") color \(snapshot.style.textColor.map { "\($0)" } ?? "nil")")
    let text = options.text.isEmpty
        ? (options.multiline
            ? " and this ghost draft keeps going past the end of the line so that it wraps onto the next lines inside the field, which is how long drafts look."
            : " ghost text after the caret")
        : options.text
    let overlay = GhostOverlay()
    overlay.show(text, for: snapshot, multiline: options.multiline)

    let start = ContinuousClock.now
    let rounds = 200
    for round in 0..<rounds {
        overlay.show(String(text.prefix(text.count - round % 5)), for: snapshot, multiline: options.multiline)
    }
    overlay.show(text, for: snapshot, multiline: options.multiline)
    print("show() update cost: \(milliseconds(start.duration(to: .now) / rounds)) per call (layout only, drawing happens on display)")

    if options.picker {
        let items = [
            PickerItem(title: "previous"), PickerItem(title: "earlier"), PickerItem(title: "last"),
            PickerItem(title: "😀", detail: "grinning face"),
        ]
        let picked = Counter()
        overlay.showPicker(items, near: snapshot.caretRect) { index in
            picked.value = index + 1
            print("picked row \(index + 1)")
        }
        if let row = options.click {
            await wait(0.5)
            let pickerHeight = CGFloat(items.count) * 24 + 10
            guard let picker = ownWindows().first(where: { abs($0.bounds.height - pickerHeight) < 1 }) else {
                print("picker window not found")
                finish(1)
            }
            _ = requireFrontmost(options)
            postMarkedClick(at: CGPoint(x: picker.bounds.midX, y: picker.bounds.minY + 5 + 24 * (CGFloat(row) - 0.5)))
            await wait(0.4)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            print("after click: picked \(picked.value), frontmost \(front), probe active \(NSApp.isActive)")
        }
    }
    for window in ownWindows() {
        print("own window layer \(window.layer) bounds \(window.bounds)")
    }
    print("visible: \(overlay.isVisible); showing for \(options.seconds) s")
    await wait(options.seconds)
    overlay.hide()
    overlay.hidePicker()
    finish()
}

@MainActor
func runInsert(_ options: Options) async {
    let text = options.text
    guard !text.isEmpty else {
        print(usage)
        finish(1)
    }
    print("Inserting \(text.utf16.count) UTF-16 units in 2 s (\(options.insertionMode))")
    await wait(2)
    let app = requireFrontmost(options)
    guard let before = readFocusedField() else {
        print("ABORT: no focused text field")
        finish(1)
    }
    let pasteboardBefore = NSPasteboard.general.pasteboardItems?.map { item in item.types.map { item.data(forType: $0) } }
    let expected = (before.value as NSString).replacingCharacters(
        in: NSRange(location: before.selection.location, length: before.selection.length),
        with: text
    )
    let start = ContinuousClock.now
    await TextInserter.insert(text, into: app.processIdentifier, mode: options.insertionMode)
    let posted = start.duration(to: .now)
    var actual = ""
    let deadline = start.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        actual = readFocusedField()?.value ?? ""
        if actual == expected { break }
        await wait(0.002)
    }
    let visible = start.duration(to: .now)
    print("events posted in \(milliseconds(posted)); text in field after \(milliseconds(visible))")
    if actual == expected {
        print("MATCH")
    } else {
        print("MISMATCH\n expected: \(escaped(expected))\n actual:   \(escaped(actual))")
    }
    var restored = true
    if options.paste {
        await wait(0.6)
        let pasteboardAfter = NSPasteboard.general.pasteboardItems?.map { item in item.types.map { item.data(forType: $0) } }
        restored = pasteboardAfter == pasteboardBefore
        print(restored ? "PASTEBOARD RESTORED" : "PASTEBOARD NOT RESTORED")
    }
    finish(actual == expected && restored ? 0 : 3)
}

@MainActor
func runDelete(_ options: Options) async {
    let count = options.words.first.flatMap(Int.init) ?? 1
    print("Deleting \(count) in 2 s")
    await wait(2)
    let app = requireFrontmost(options)
    let before = readFocusedField()?.value ?? ""
    await TextInserter.deleteBackward(count: count, in: app.processIdentifier)
    await wait(0.3)
    let after = readFocusedField()?.value ?? ""
    print("characters before \(before.count), after \(after.count)")
    finish()
}

@MainActor
func runTab(_ options: Options) async {
    print("Posting Tab in 2 s")
    await wait(2)
    let app = requireFrontmost(options)
    let before = readFocusedField()?.value ?? ""
    TextInserter.postTab(to: app.processIdentifier)
    await wait(0.3)
    let after = readFocusedField()?.value ?? ""
    print("tabs before \(before.filter { $0 == "\t" }.count), after \(after.filter { $0 == "\t" }.count)")
    finish()
}

@MainActor
final class Counter {
    var value = 0
}

@MainActor
func runMonitor(_ options: Options) async {
    let monitor = KeyMonitor()
    let keys = Counter()
    monitor.onKey = { key in
        keys.value += 1
        print("\(key.kind) keyCode=\(key.keyCode) modifiers=0x\(String(key.modifiers, radix: 16)) characters=\"\(escaped(key.characters))\"")
    }
    monitor.onPointer = { print("pointer") }
    guard monitor.start() else {
        print("Key tap could not be created (permission missing)")
        finish(1)
    }
    print("Monitoring for \(options.seconds) s")
    if options.selftest {
        await wait(1)
        _ = requireFrontmost(options)
        let seen = keys.value
        for _ in 0..<5 {
            postMarkedKeyThroughHID(keyCode: kVK_ANSI_X, characters: "x")
        }
        await wait(0.5)
        let leaked = keys.value - seen
        print(leaked == 0 ? "SELFTEST PASS: 5 marked key presses ignored" : "SELFTEST FAIL: \(leaked) marked events reported")
    }
    await wait(options.seconds)
    monitor.stop()
    finish()
}

@MainActor
func runHotKey(_ options: Options) async {
    let center = HotKeyCenter()
    let presses = Counter()
    let action: @MainActor () -> Void = {
        presses.value += 1
        print("Tab hot key pressed (\(presses.value))")
    }
    guard center.register(.tab, action: action) else {
        print("Tab registration failed")
        finish(1)
    }
    print("Tab registered for \(options.seconds) s")
    guard options.selftest else {
        await wait(options.seconds)
        center.unregisterAll()
        finish()
    }

    await wait(1)
    let app = requireFrontmost(options)
    func tabs() -> Int { readFocusedField()?.value.filter { $0 == "\t" }.count ?? -1 }
    var results: [(String, Bool)] = []

    let tabsStart = tabs()
    postMarkedKeyThroughHID(keyCode: kVK_Tab)
    await wait(0.3)
    results.append(("registered: Tab fires the action and is swallowed", presses.value == 1 && tabs() == tabsStart))

    center.unregister(.tab)
    postMarkedKeyThroughHID(keyCode: kVK_Tab)
    await wait(0.3)
    results.append(("unregistered: Tab reaches the app", presses.value == 1 && tabs() == tabsStart + 1))

    center.register(.tab, action: action)
    TextInserter.postTab(to: app.processIdentifier)
    await wait(0.3)
    results.append(("registered: postTab(to:) bypasses the hot key", presses.value == 1 && tabs() == tabsStart + 2))

    postMarkedKeyThroughHID(keyCode: kVK_Tab)
    await wait(0.3)
    results.append(("re-registered: Tab fires again", presses.value == 2 && tabs() == tabsStart + 2))

    let cycles = 500
    let start = ContinuousClock.now
    for _ in 0..<cycles {
        center.unregister(.tab)
        center.register(.tab, action: action)
    }
    print("unregister + register: \(milliseconds(start.duration(to: .now) / cycles)) per cycle")
    center.unregisterAll()

    for (name, passed) in results {
        print("\(passed ? "PASS" : "FAIL"): \(name)")
    }
    finish(results.allSatisfy(\.1) ? 0 : 3)
}

// MARK: Main

setvbuf(stdout, nil, _IOLBF, 0)
let options = Options(Array(CommandLine.arguments.dropFirst()))
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

Task { @MainActor in
    switch options.command {
    case "overlay": await runOverlay(options)
    case "insert": await runInsert(options)
    case "delete": await runDelete(options)
    case "tab": await runTab(options)
    case "monitor": await runMonitor(options)
    case "hotkey": await runHotKey(options)
    default:
        print(usage)
        finish(options.command.isEmpty ? 0 : 1)
    }
}
application.run()
