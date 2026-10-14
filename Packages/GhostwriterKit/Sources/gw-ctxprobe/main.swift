import Actions
import AppKit
import ApplicationServices
import Foundation
import GWCore
import ScreenContext

let usage = """
    usage: gw-ctxprobe <command>
      screen [--app <bundle id>] [--delay <s>] [--flag manual|enhanced|both] [--wait <s>] [--ocr default|always|never]
             [--ocr-below <chars>] [--lang <code>] [--max <chars>]
          read the focused field of the frontmost (or given) app and run its screen context; counts only
      window --app <bundle id> [--caret center|top|bottom] [same options as screen]
          the same on the app's front window, without a focused field
      flags --app <bundle id> [--role] [--flag manual|enhanced|both] [--watch <s>]
          focus and tree size over time after reading the app role and writing the web flags (never false)
      census --app <bundle id> [--focused]
          whole accessibility tree of the front window: node, role and text-character counts, call latency
      focus --app <bundle id> --role <AXRole> [--pick bottom|largest|first] [--frontmost]
          set AXFocused on a matching element (focus tests, under the focus lock; no synthetic events)
      ocr <image.png> <x> <y> <width> <height> [--caret <x> <y>] [--lang <code>] [--prewarm]
          run the OCR stage on an image showing that screen rect (points, top-left origin)
      warm [<language>...]
          warm the OCR models for automatic detection, then for each field language, timing each
      clip [--wait <s>] [--max-age <s>]
          watch the clipboard and print what ClipboardReader returns after each change
      action <rephrase|fixGrammar|shorten|expand|formal|casual|translate> <text> [--to <language>] [--prewarm <s>]
      synonyms <word> <sentence>
      fill <instruction> [context]
    """

let clock = ContinuousClock()

func ms(_ duration: Duration) -> String {
    let parts = duration.components
    return String(format: "%.1f ms", Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - AX helpers (minimal; the app uses Capture)

func copyAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func asElement(_ value: AnyObject?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

func axValue<T: BitwiseCopyable>(_ value: AnyObject?, _ type: AXValueType, _ empty: T) -> T? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    var result = empty
    return AXValueGetValue(axValue, type, &result) ? result : nil
}

func frame(of element: AXUIElement) -> CGRect {
    let origin = axValue(copyAttribute(element, kAXPositionAttribute), .cgPoint, CGPoint.zero) ?? .zero
    let size = axValue(copyAttribute(element, kAXSizeAttribute), .cgSize, CGSize.zero) ?? .zero
    return CGRect(origin: origin, size: size)
}

func bounds(of element: AXUIElement, range: CFRange) -> CGRect? {
    var range = range
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
        element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result
    ) == .success else { return nil }
    return axValue(result, .cgRect, CGRect.zero)
}

func focusedSnapshot(of app: NSRunningApplication) -> FieldSnapshot? {
    let pid = app.processIdentifier
    let appElement = AXUIElementCreateApplication(pid)
    guard let focused = asElement(copyAttribute(appElement, kAXFocusedUIElementAttribute)) else { return nil }
    let value = copyAttribute(focused, kAXValueAttribute) as? String ?? ""
    let selection = axValue(copyAttribute(focused, kAXSelectedTextRangeAttribute), .cfRange, CFRange())
        ?? CFRange(location: (value as NSString).length, length: 0)
    let text = value as NSString
    let location = min(max(selection.location, 0), text.length)
    let end = min(location + max(selection.length, 0), text.length)
    var caret = bounds(of: focused, range: CFRange(location: location, length: 0)) ?? .zero
    if caret.height == 0, location > 0 {
        caret = bounds(of: focused, range: CFRange(location: location - 1, length: 1)) ?? .zero
    }
    let window = asElement(copyAttribute(focused, kAXWindowAttribute))
    return FieldSnapshot(
        id: FieldID(pid: pid, elementHash: CFHash(focused)),
        app: AppIdentity(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "", pid: pid),
        textBefore: text.substring(to: location),
        textAfter: text.substring(from: end),
        selectedText: text.substring(with: NSRange(location: location, length: end - location)),
        caretRect: caret,
        fieldFrame: frame(of: focused),
        windowTitle: window.flatMap { copyAttribute($0, kAXTitleAttribute) as? String }
    )
}

// MARK: - Commands

func screen(_ args: [String]) async {
    let delay = Double(option("--delay", in: args) ?? "3") ?? 3
    print("waiting \(delay) s; focus a text field…")
    try? await Task.sleep(for: .seconds(delay))
    let app: NSRunningApplication?
    if let bundleID = option("--app", in: args) {
        app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    } else {
        app = NSWorkspace.shared.frontmostApplication
    }
    guard let app else { fail("app not found") }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    await wakeWebTree(appElement, args: args)
    guard let snapshot = focusedSnapshot(of: app) else { fail("no focused element in \(app.localizedName ?? "?")") }
    print("app: \(snapshot.app.bundleID), window title: \(snapshot.windowTitle?.count ?? 0) chars")
    print(focusedSummary(of: appElement))
    print("field: \(describe(snapshot.fieldFrame)), caret: \(describe(snapshot.caretRect)), "
        + "field text: \(snapshot.textBefore.count + snapshot.textAfter.count) chars")
    print("screen recording granted: \(ScreenRecordingPermission.isGranted)")
    await runPipeline(snapshot, options: pipelineOptions(args))
}

func ocr(_ args: [String]) async {
    guard args.count >= 5, let x = Double(args[1]), let y = Double(args[2]), let width = Double(args[3]),
          let height = Double(args[4])
    else { fail(usage) }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[0]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("cannot read image") }
    let imageFrame = CGRect(x: x, y: y, width: width, height: height)
    var caret = CGRect(x: imageFrame.midX, y: imageFrame.maxY - 40, width: 1, height: 16)
    if let index = args.firstIndex(of: "--caret"), index + 2 < args.count,
       let cx = Double(args[index + 1]), let cy = Double(args[index + 2]) {
        caret = CGRect(x: cx, y: cy, width: 1, height: 16)
    }
    let snapshot = FieldSnapshot(
        id: FieldID(pid: 0, elementHash: 0), app: AppIdentity(bundleID: "", name: "", pid: 0),
        textBefore: "", textAfter: "", caretRect: caret,
        fieldFrame: CGRect(x: caret.minX - 10, y: caret.minY - 10, width: 400, height: 80)
    )
    var options = ScreenContextOptions()
    options.language = option("--lang", in: args)
    if args.contains("--prewarm") {
        let warm = clock.now
        await ScreenContextProvider.prewarmOCR(languages: options.language.map { [$0] } ?? [])
        print("prewarm: \(ms(clock.now - warm))")
    }
    let start = clock.now
    do {
        let text = try await ScreenContextProvider.ocrText(
            of: image, imageFrame: imageFrame, for: snapshot, options: options
        )
        print("ocr: \(image.width)x\(image.height) px in \(ms(clock.now - start))")
        print("----- context (\(text?.count ?? 0) chars) -----\n\(text ?? "<nil>")")
    } catch {
        fail("ocr failed: \(error)")
    }
}

func warm(_ args: [String]) async {
    var start = clock.now
    await ScreenContextProvider.prewarmOCR(languages: [])
    print("automatic: \(ms(clock.now - start))")
    for language in args {
        start = clock.now
        await ScreenContextProvider.prewarmOCR(languages: [language])
        print("\(language): \(ms(clock.now - start))")
    }
}

@MainActor
func clip(_ args: [String]) async {
    let wait = Double(option("--wait", in: args) ?? "10") ?? 10
    let maxAge = Double(option("--max-age", in: args) ?? "600") ?? 600
    ClipboardReader.startMonitoring()
    print("initial: \(ClipboardReader.recentText(maxAge: maxAge, maxCharacters: 2000) ?? "<nil>")")
    var lastCount = NSPasteboard.general.changeCount
    let deadline = clock.now + .seconds(wait)
    while clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(200))
        let count = NSPasteboard.general.changeCount
        guard count != lastCount else { continue }
        lastCount = count
        let types = NSPasteboard.general.types?.map(\.rawValue).joined(separator: ", ") ?? ""
        let text = ClipboardReader.recentText(maxAge: maxAge, maxCharacters: 2000)
        print("change \(count) [\(types)]: \(text.map { "\"\($0)\"" } ?? "<nil>")")
    }
}

func action(_ args: [String]) async {
    guard args.count >= 2, let action = WritingAction(rawValue: args[0]) else { fail(usage) }
    let target = option("--to", in: args)
    print("available: \(WritingAssistant.isAvailable) \(WritingAssistant.unavailableReason ?? "")")
    if let seconds = option("--prewarm", in: args).flatMap(Double.init) {
        WritingAssistant().prewarm()
        try? await Task.sleep(for: .seconds(seconds))
    }
    let start = clock.now
    var firstChunk: Duration?
    var chunks = 0
    var latest = ""
    do {
        for try await text in WritingAssistant().run(action, on: args[1], targetLanguage: target) {
            if firstChunk == nil { firstChunk = clock.now - start }
            chunks += 1
            latest = text
        }
        print("first chunk: \(firstChunk.map(ms) ?? "-"), total: \(ms(clock.now - start)), snapshots: \(chunks)")
        print("----- \(action.rawValue) -----\n\(latest)")
    } catch {
        print("first chunk: \(firstChunk.map(ms) ?? "-"), failed after \(ms(clock.now - start))")
        print("error: \(error.localizedDescription)")
    }
}

func synonyms(_ args: [String]) async {
    guard args.count >= 2 else { fail(usage) }
    let start = clock.now
    do {
        let words = try await WritingAssistant().synonyms(for: args[0], in: args[1])
        print("synonyms in \(ms(clock.now - start)): \(words)")
    } catch {
        print("failed after \(ms(clock.now - start)): \(error.localizedDescription)")
    }
}

func fill(_ args: [String]) async {
    guard !args.isEmpty else { fail(usage) }
    let start = clock.now
    do {
        let text = try await WritingAssistant().fill(instruction: args[0], context: args.count > 1 ? args[1] : "")
        print("fill in \(ms(clock.now - start)):\n\(text)")
    } catch {
        print("failed after \(ms(clock.now - start)): \(error.localizedDescription)")
    }
}

// ScreenCaptureKit needs a window-server connection, which NSApplication sets up.
_ = NSApplication.shared
let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }
let rest = Array(arguments.dropFirst())
switch command {
case "screen": await screen(rest)
case "flags": await flagsCommand(rest)
case "census": censusCommand(rest)
case "window": await windowCommand(rest)
case "focus": await focusCommand(rest)
case "ocr": await ocr(rest)
case "warm": await warm(rest)
case "clip": await clip(rest)
case "action": await action(rest)
case "synonyms": await synonyms(rest)
case "fill": await fill(rest)
default: fail(usage)
}
