import AppKit
import ApplicationServices

@MainActor
enum AXTools {
    static func dumpFocused() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return print("no frontmost app") }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        print("app \(app.bundleIdentifier ?? "-") pid \(app.processIdentifier)")
        guard let focused = element(appElement, kAXFocusedUIElementAttribute) else { return print("no focused element") }
        dump(focused, label: "focused", full: true)
        var current = element(focused, kAXParentAttribute)
        var depth = 1
        while let ancestor = current, depth <= 40 {
            dump(ancestor, label: "ancestor \(depth)", full: false)
            current = element(ancestor, kAXParentAttribute)
            depth += 1
        }
    }

    static func focus(bundleID: String, domID: String, caret: Int?) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return print("\(bundleID) not running")
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(appElement, kAXFocusedWindowAttribute) else { return print("no focused window") }
        guard let target = find(domID, in: window) else { return print("no element with DOM id \(domID)") }
        print("focus \(domID): \(AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)")
        if let caret { setSelection(target, location: caret, length: 0) }
    }

    static func select(location: Int, length: Int) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let focused = element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
        else { return print("no focused element") }
        setSelection(focused, location: location, length: length)
    }

    private static func setSelection(_ element: AXUIElement, location: Int, length: Int) {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return print("cannot create range") }
        print("select \(location),\(length): \(AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value).rawValue)")
    }

    private static func find(_ domID: String, in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 20_000 {
            let node = queue.removeFirst()
            visited += 1
            if string(node, "AXDOMIdentifier") == domID { return node }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AnyObject] {
                queue += list.compactMap(asElement)
            }
        }
        return nil
    }

    private static func dump(_ element: AXUIElement, label: String, full: Bool) {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let attributes = names as? [String] else {
            return print("\(label): cannot read attribute names")
        }
        if !full {
            let keys = ["AXRole", "AXSubrole", "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList", "AXDescription", "AXTitle", "AXURL"]
            print("\(label): " + keys.compactMap { key in value(element, key).map { "\(key)=\(describe($0))" } }.joined(separator: " "))
            return
        }
        print("\(label):")
        for attribute in attributes.sorted() {
            print("  \(attribute) = \(value(element, attribute).map(describe) ?? "<error>")")
        }
        var parameterized: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(element, &parameterized) == .success, let list = parameterized as? [String] {
            print("  parameterized: \(list.sorted().joined(separator: " "))")
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            print("  AXValue settable: \(settable.boolValue)")
        }
        var selection = CFRange()
        if let value = value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID(),
           AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &selection) {
            let caret = selection.location + selection.length
            for range in [CFRange(location: caret, length: 0), CFRange(location: max(0, caret - 1), length: 1), CFRange(location: 0, length: 1)] {
                print("  bounds(\(range.location),\(range.length)) = \(bounds(element, range))")
            }
            var styleRange = CFRange(location: max(0, caret - 1), length: 1)
            var attributed: CFTypeRef?
            if let parameter = AXValueCreate(.cfRange, &styleRange),
               AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &attributed) == .success,
               let string = attributed as? NSAttributedString, string.length > 0 {
                for (key, value) in string.attributes(at: 0, effectiveRange: nil) {
                    let space = CFGetTypeID(value as AnyObject) == CGColor.typeID
                        ? " space=\(unsafeDowncast(value as AnyObject, to: CGColor.self).colorSpace.map { String(describing: $0) } ?? "-")" : ""
                    print("  style \(key.rawValue) = \(String(describing: value).replacingOccurrences(of: "\n", with: " "))\(space)")
                }
            }
        }
    }

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> String {
        var range = range
        var result: CFTypeRef?
        guard let parameter = AXValueCreate(.cfRange, &range) else { return "-" }
        let error = AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result)
        var rect = CGRect.zero
        guard error == .success, let result, CFGetTypeID(result) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(result, to: AXValue.self), .cgRect, &rect) else { return "error \(error.rawValue)" }
        return "\(rect)"
    }

    private static func describe(_ value: CFTypeRef) -> String {
        if let text = value as? String {
            let flat = text.replacingOccurrences(of: "\n", with: "⏎")
            return flat.count > 80 ? "\"\(flat.prefix(80))…\" (\(text.utf16.count))" : "\"\(flat)\""
        }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return "<element>" }
        if let array = value as? [AnyObject] {
            return array.count > 6 ? "[\(array.count) items]" : "[" + array.map(describe).joined(separator: ", ") + "]"
        }
        return String(describing: value).replacingOccurrences(of: "\n", with: " ")
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        value(element, attribute).flatMap(asElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func asElement(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
