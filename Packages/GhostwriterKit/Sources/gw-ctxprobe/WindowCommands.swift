import AppKit
import ApplicationServices
import Foundation
import GWCore
import ScreenContext

// Window and tree commands. They print counts, roles, frames and timings only, never screen text.

let manualAccessibility = "AXManualAccessibility"
let enhancedUserInterface = "AXEnhancedUserInterface"

func uptime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func msSince(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

func targetApp(_ args: [String]) -> NSRunningApplication {
    guard let bundleID = option("--app", in: args) else { fail("--app <bundle id> required") }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        fail("not running: \(bundleID)")
    }
    return app
}

struct NodeRead {
    var role: String
    var subrole: String
    var valueLength: Int?
    var children: [AXUIElement]
    var frame: CGRect?
}

private let nodeAttributes = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXChildrenAttribute,
    kAXPositionAttribute, kAXSizeAttribute,
]

func readNode(_ element: AXUIElement) -> NodeRead? {
    var raw: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, nodeAttributes as CFArray, [], &raw) == .success,
          let values = raw as? [AnyObject], values.count == 6, let role = values[0] as? String
    else { return nil }
    let children = (values[3] as? [AnyObject] ?? []).compactMap { asElement($0) }
    let origin = axValue(values[4], .cgPoint, CGPoint.zero)
    let size = axValue(values[5], .cgSize, CGSize.zero)
    let frame = origin.flatMap { origin in size.map { CGRect(origin: origin, size: $0) } }
    return NodeRead(
        role: role, subrole: values[1] as? String ?? "", valueLength: (values[2] as? String)?.count,
        children: children, frame: frame
    )
}

func describe(_ rect: CGRect?) -> String {
    guard let rect else { return "-" }
    return "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
}

// MARK: - Census: the whole tree under an element, no time budget

struct Census {
    var nodes = 0
    var failed = 0
    var roles: [String: Int] = [:]
    var textNodes = 0
    var textCharacters = 0
    var visibleTextCharacters = 0
    var webAreas = 0
    var maxDepth = 0
    var callMs: [Double] = []
    var elapsedMs = 0.0
    var capped = false

    var summary: String {
        let sorted = callMs.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        return "nodes \(nodes) (failed \(failed)), depth \(maxDepth), web areas \(webAreas), text nodes \(textNodes), "
            + "text chars \(textCharacters) (in window \(visibleTextCharacters)), "
            + "call ms mean \(fmt(mean)) p50 \(fmt(percentile(0.5))) p95 \(fmt(percentile(0.95))) max \(fmt(sorted.last ?? 0)), "
            + "total \(fmt(elapsedMs)) ms\(capped ? ", CAPPED" : "")"
    }

    var topRoles: String {
        roles.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}

private let textRoles: Set<String> = [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole]

func census(of root: AXUIElement, clip: CGRect, maxNodes: Int = 20000, maxSeconds: Double = 5) -> Census {
    var result = Census()
    let start = uptime()
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var head = 0
    while head < queue.count {
        if result.nodes >= maxNodes || msSince(start) > maxSeconds * 1000 {
            result.capped = true
            break
        }
        let (element, depth) = queue[head]
        head += 1
        AXUIElementSetMessagingTimeout(element, 1.0)
        let callStart = uptime()
        let node = readNode(element)
        result.callMs.append(msSince(callStart))
        result.nodes += 1
        guard let node else {
            result.failed += 1
            continue
        }
        result.maxDepth = max(result.maxDepth, depth)
        result.roles[node.role, default: 0] += 1
        if node.role == "AXWebArea" { result.webAreas += 1 }
        if let length = node.valueLength, length > 0, textRoles.contains(node.role),
           node.subrole != kAXSecureTextFieldSubrole {
            result.textNodes += 1
            result.textCharacters += length
            if let frame = node.frame, clip.isEmpty || frame.intersects(clip) { result.visibleTextCharacters += length }
        }
        for child in node.children { queue.append((child, depth + 1)) }
    }
    result.elapsedMs = msSince(start)
    return result
}

// MARK: - Window and focus

func window(of appElement: AXUIElement) -> (element: AXUIElement, source: String)? {
    if let window = asElement(copyAttribute(appElement, kAXFocusedWindowAttribute)) { return (window, "focused") }
    if let window = asElement(copyAttribute(appElement, kAXMainWindowAttribute)) { return (window, "main") }
    if let windows = copyAttribute(appElement, kAXWindowsAttribute) as? [AnyObject],
       let first = windows.compactMap({ asElement($0) }).first {
        return (first, "first")
    }
    return nil
}

func focusedElement(of appElement: AXUIElement) -> (AXUIElement?, AXError) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
    return (error == .success ? asElement(value) : nil, error)
}

func focusedSummary(of appElement: AXUIElement) -> String {
    let (element, error) = focusedElement(of: appElement)
    guard let element else { return "focused none (AXError \(error.rawValue))" }
    guard let node = readNode(element) else { return "focused unreadable" }
    let characters = (copyAttribute(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
    return "focused \(node.role)/\(node.subrole.isEmpty ? "-" : node.subrole) frame \(describe(node.frame)) "
        + "children \(node.children.count) chars \(characters.map(String.init) ?? "-")"
}

// MARK: - Web accessibility (the app's steps: read the role, write flags true; never false)

func readFlag(_ appElement: AXUIElement, _ name: String) -> String {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(appElement, name as CFString, &value)
    guard error == .success else { return "AXError \(error.rawValue)" }
    guard let value else { return "nil" }
    if let number = value as? NSNumber { return number.boolValue ? "true" : "false" }
    return "\(value)"
}

func flagNames(_ choice: String?) -> [String] {
    switch choice {
    case "manual": [manualAccessibility]
    case "enhanced": [enhancedUserInterface]
    case "both": [manualAccessibility, enhancedUserInterface]
    case nil, "none": []
    default: fail("--flag manual|enhanced|both|none")
    }
}

func readRole(_ appElement: AXUIElement) {
    var value: CFTypeRef?
    let start = uptime()
    let error = AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &value)
    print("  read app AXRole: AXError \(error.rawValue), \(fmt(msSince(start))) ms")
}

func enableFlags(_ names: [String], on appElement: AXUIElement) {
    for name in names {
        let error = AXUIElementSetAttributeValue(appElement, name as CFString, kCFBooleanTrue)
        print("  set \(name)=true: AXError \(error.rawValue), reads back \(readFlag(appElement, name))")
    }
}

func printFlags(_ appElement: AXUIElement, _ label: String) {
    print("\(label): \(manualAccessibility)=\(readFlag(appElement, manualAccessibility)), "
        + "\(enhancedUserInterface)=\(readFlag(appElement, enhancedUserInterface))")
}

func wakeWebTree(_ appElement: AXUIElement, args: [String]) async {
    readRole(appElement)
    let names = flagNames(option("--flag", in: args))
    enableFlags(names, on: appElement)
    let wait = Double(option("--wait", in: args) ?? (names.isEmpty ? "0.3" : "2.5")) ?? 0.3
    try? await Task.sleep(for: .seconds(wait))
}

func flagsCommand(_ args: [String]) async {
    let app = targetApp(args)
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 1.0)
    let names = flagNames(option("--flag", in: args))
    let watch = Double(option("--watch", in: args) ?? "6") ?? 6
    print("app \(app.bundleIdentifier ?? "?") pid \(app.processIdentifier) active \(app.isActive)")
    printFlags(appElement, "flags before")
    let windowFrame = window(of: appElement).flatMap { readNode($0.element)?.frame } ?? .zero

    func checkpoint(_ label: String) {
        let focus = focusedSummary(of: appElement)
        guard let window = window(of: appElement) else {
            print("\(label): \(focus); no window")
            return
        }
        let result = census(of: window.element, clip: windowFrame, maxNodes: 20000, maxSeconds: 4)
        print("\(label): \(focus)\n    window(\(window.source)) \(result.summary)")
    }

    checkpoint("before")
    let written = uptime()
    if args.contains("--role") { readRole(appElement) }
    enableFlags(names, on: appElement)
    var marks: [Double] = [0, 0.1, 0.15, 0.3, 0.5, 1, 1.5, 2, 2.25, 2.5, 3, 4, 6, 10].filter { $0 <= watch }
    while !marks.isEmpty {
        let mark = marks.removeFirst()
        let wait = mark * 1000 - msSince(written)
        if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait))) }
        checkpoint("t=\(Int(msSince(written))) ms")
    }
    printFlags(appElement, "flags after")
}

func censusCommand(_ args: [String]) {
    let app = targetApp(args)
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 1.0)
    printFlags(appElement, "flags")
    print(focusedSummary(of: appElement))
    guard let window = window(of: appElement) else { fail("no window") }
    let windowFrame = readNode(window.element)?.frame ?? .zero
    print("window(\(window.source)) frame \(describe(windowFrame))")
    let root = args.contains("--focused") ? (focusedElement(of: appElement).0 ?? window.element) : window.element
    let result = census(of: root, clip: windowFrame)
    print(result.summary)
    print("roles: \(result.topRoles)")
}

// MARK: - Pipeline on the front window, no focused field needed

func syntheticSnapshot(_ app: NSRunningApplication, windowFrame: CGRect, caret: String) -> FieldSnapshot {
    let y: CGFloat = switch caret {
    case "top": windowFrame.minY + 80
    case "bottom": windowFrame.maxY - 80
    default: windowFrame.midY
    }
    return FieldSnapshot(
        id: FieldID(pid: app.processIdentifier, elementHash: UInt(bitPattern: Int(y))),
        app: AppIdentity(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "", pid: app.processIdentifier),
        textBefore: "", textAfter: "",
        caretRect: CGRect(x: windowFrame.midX, y: y, width: 1, height: 16),
        fieldFrame: .zero
    )
}

func windowCommand(_ args: [String]) async {
    let app = targetApp(args)
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 1.0)
    await wakeWebTree(appElement, args: args)
    guard let window = window(of: appElement), let windowFrame = readNode(window.element)?.frame else {
        print("no AX window")
        return
    }
    print("app \(app.bundleIdentifier ?? "?") window(\(window.source)) \(describe(windowFrame)); \(focusedSummary(of: appElement))")
    let snapshot = syntheticSnapshot(app, windowFrame: windowFrame, caret: option("--caret", in: args) ?? "center")
    await runPipeline(snapshot, options: pipelineOptions(args))
}

func pipelineOptions(_ args: [String]) -> ScreenContextOptions {
    var options = ScreenContextOptions()
    switch option("--ocr", in: args) ?? "default" {
    case "always": options.ocrBelowAXCharacters = .max
    case "never": options.allowOCR = false
    default: break
    }
    if let threshold = option("--ocr-below", in: args).flatMap(Int.init) { options.ocrBelowAXCharacters = threshold }
    if let max = option("--max", in: args).flatMap(Int.init) { options.maxCharacters = max }
    options.language = option("--lang", in: args)
    return options
}

func runPipeline(_ snapshot: FieldSnapshot, options: ScreenContextOptions) async {
    if options.allowOCR {
        let start = uptime()
        await ScreenContextProvider.prewarmOCR(languages: ["en"] + (options.language.map { [$0] } ?? []))
        print("ocr models ready: \(fmt(msSince(start))) ms")
    }
    let provider = ScreenContextProvider()
    var start = uptime()
    let first = await provider.text(for: snapshot, options: options)
    print("first focus: \(fmt(msSince(start))) ms, \(first?.count ?? 0) chars; \(await provider.lastScanSummary() ?? "-")")
    start = uptime()
    let swapped = await provider.textAfterOCR(for: snapshot, options: options)
    print("after ocr: \(fmt(msSince(start))) ms, \(swapped.map { "\($0.count) chars" } ?? "no swap"); "
        + "\(await provider.lastScanSummary() ?? "-")")
}

// MARK: - Focus (for focus tests only; no synthetic events)

/// Setting focus can activate the app: hold the focus lock.
func focusCommand(_ args: [String]) async {
    let app = targetApp(args)
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appElement, 1.0)
    if args.contains("--frontmost") {
        let error = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        print("set AXFrontmost: AXError \(error.rawValue)")
        try? await Task.sleep(for: .milliseconds(400))
    }
    guard let role = option("--role", in: args) else { fail("--role required") }
    guard let window = window(of: appElement) else { fail("no window") }
    var matches: [(element: AXUIElement, frame: CGRect)] = []
    var queue = [window.element]
    var head = 0
    while head < queue.count, head < 20000 {
        let element = queue[head]
        head += 1
        guard let node = readNode(element) else { continue }
        if node.role == role { matches.append((element, node.frame ?? .zero)) }
        queue.append(contentsOf: node.children)
    }
    for (index, match) in matches.enumerated() { print("  \(role) #\(index): \(describe(match.frame))") }
    let pick: (element: AXUIElement, frame: CGRect)? = switch option("--pick", in: args) ?? "bottom" {
    case "largest": matches.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    case "first": matches.first
    default: matches.max { $0.frame.maxY < $1.frame.maxY }
    }
    guard let pick else { fail("no \(role) found") }
    let error = AXUIElementSetAttributeValue(pick.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    print("set AXFocused on \(role) \(describe(pick.frame)): AXError \(error.rawValue)")
    try? await Task.sleep(for: .milliseconds(300))
    print(focusedSummary(of: appElement))
}

