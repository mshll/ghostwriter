import ApplicationServices
import CoreGraphics
import Foundation

struct AXWindowScan: Sendable {
    var windowFrame: CGRect
    var chunks: [TextChunk]
    var nodesVisited: Int
    var elapsedMs: Double
    var hitBudget: Bool
}

struct AXScanBudget: Sendable {
    var seconds: Double = 0.15
    var nodes: Int = 3000
    /// Short, so one slow node costs a little of the budget instead of all of it.
    var messagingTimeout: Float = 0.05
}

enum AXWindowReader {
    private static let queue = DispatchQueue(label: "com.mshl.ghostwriter.screencontext.ax", qos: .userInitiated)

    static func scan(
        pid: pid_t, caret: CGRect, field: CGRect, fieldText: String, budget: AXScanBudget = AXScanBudget()
    ) async -> AXWindowScan? {
        await withCheckedContinuation { continuation in
            queue.async {
                var walker = Walker(pid: pid, caret: caret, field: field, fieldText: fieldText, budget: budget)
                continuation.resume(returning: walker.run())
            }
        }
    }
}

private let chromeRoles: Set<String> = [
    kAXButtonRole, kAXMenuBarRole, kAXMenuBarItemRole, kAXMenuRole, kAXMenuItemRole, kAXMenuButtonRole,
    kAXPopUpButtonRole, kAXToolbarRole, kAXScrollBarRole, kAXSplitterRole, kAXCheckBoxRole,
    kAXRadioButtonRole, kAXSliderRole, kAXIncrementorRole, kAXDisclosureTriangleRole, kAXImageRole,
    kAXComboBoxRole, kAXColorWellRole, kAXProgressIndicatorRole, kAXBusyIndicatorRole,
    kAXValueIndicatorRole, kAXRulerRole, kAXGrowAreaRole, kAXHandleRole,
]
private let textInputRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole]
private let skippedSubroles: Set<String> = [kAXSecureTextFieldSubrole, kAXSearchFieldSubrole]
private let inlineRoles: Set<String> = ["AXLink"]
private let clippingRoles: Set<String> = [kAXScrollAreaRole, kAXWindowRole]
private let estimatedChildSpacing: CGFloat = 20
private let maxChildrenPerContainer = 400

private let attributeNames = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXChildrenAttribute,
    kAXPositionAttribute, kAXSizeAttribute,
]

private struct Node {
    var element: AXUIElement
    var path: [Int]
    var blockPath: [Int]
    var blockFrame: CGRect
    var clip: CGRect
    var priority: CGFloat
}

private struct Fragment {
    var text: String
    var frame: CGRect
    var path: [Int]
    var blockPath: [Int]
    var blockFrame: CGRect
}

private struct Walker {
    let pid: pid_t
    let caret: CGRect
    let field: CGRect
    let fieldText: String
    let budget: AXScanBudget
    let attributes = attributeNames as CFArray

    init(pid: pid_t, caret: CGRect, field: CGRect, fieldText: String, budget: AXScanBudget) {
        self.pid = pid
        self.caret = caret
        self.field = field
        self.fieldText = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.budget = budget
    }

    mutating func run() -> AXWindowScan? {
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + UInt64(budget.seconds * 1e9)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, budget.messagingTimeout)
        let focused = copyElement(app, kAXFocusedUIElementAttribute)
        if let focused { AXUIElementSetMessagingTimeout(focused, budget.messagingTimeout) }
        guard let window = copyElement(app, kAXFocusedWindowAttribute)
            ?? focused.flatMap({ copyElement($0, kAXWindowAttribute) })
        else { return nil }
        AXUIElementSetMessagingTimeout(window, budget.messagingTimeout)
        let windowFrame = frame(of: window) ?? .zero

        var heap = NodeHeap()
        heap.push(Node(
            element: window, path: [], blockPath: [], blockFrame: windowFrame, clip: windowFrame, priority: 0
        ))
        var fragments: [Fragment] = []
        var visited = 0
        var hitBudget = false

        while let node = heap.pop() {
            if visited >= budget.nodes || DispatchTime.now().uptimeNanoseconds > deadline {
                hitBudget = true
                break
            }
            visited += 1
            if let focused, CFEqual(node.element, focused) { continue }
            guard let info = read(node.element) else { continue }
            if chromeRoles.contains(info.role) || skippedSubroles.contains(info.subrole) { continue }

            var clip = node.clip
            if let frame = info.frame, !frame.isEmpty {
                guard clip.isEmpty || frame.intersects(clip) else { continue }
                if ScreenText.isFieldFrame(frame, field), textInputRoles.contains(info.role) { continue }
                if clippingRoles.contains(info.role) { clip = clip.isEmpty ? frame : clip.intersection(frame) }
            }

            if let text = info.value, info.role == kAXStaticTextRole || textInputRoles.contains(info.role) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != fieldText, let frame = info.frame {
                    let isInline = info.role == kAXStaticTextRole
                    fragments.append(Fragment(
                        text: text, frame: frame, path: node.path,
                        blockPath: isInline ? node.blockPath : node.path,
                        blockFrame: isInline ? node.blockFrame : frame
                    ))
                }
                continue
            }

            let isInline = inlineRoles.contains(info.role)
            let blockPath = isInline ? node.blockPath : node.path
            let blockFrame = isInline ? node.blockFrame : info.frame ?? node.blockFrame
            let childPriority = info.frame.map { childPriorityFor($0, parent: node.priority) } ?? node.priority
            let pivot = info.children.count > 16
                ? caretIndex(in: info.children, visited: &visited, deadline: deadline) : nil
            for index in queuedRange(count: info.children.count, around: pivot) {
                if DispatchTime.now().uptimeNanoseconds > deadline {
                    hitBudget = true
                    break
                }
                let child = info.children[index]
                AXUIElementSetMessagingTimeout(child, budget.messagingTimeout)
                var priority = childPriority
                if let pivot {
                    let steps = index < pivot
                        ? CGFloat(pivot - 1 - index) : CGFloat(index - pivot) * ScreenText.belowCaretPenalty
                    priority += steps * estimatedChildSpacing
                }
                heap.push(Node(
                    element: child, path: node.path + [index], blockPath: blockPath, blockFrame: blockFrame,
                    clip: clip, priority: priority
                ))
            }
            if hitBudget { break }
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        return AXWindowScan(
            windowFrame: windowFrame, chunks: paragraphs(from: fragments),
            nodesVisited: visited, elapsedMs: elapsed, hitBudget: hitBudget
        )
    }

    /// Index of the first child not entirely above the caret, by binary search. Children of long
    /// containers (threads, documents) are laid out top to bottom in order, so this finds the caret's
    /// neighbourhood in a few reads instead of reading every child from the top.
    private func caretIndex(in children: [AXUIElement], visited: inout Int, deadline: UInt64) -> Int? {
        var low = 0, high = children.count
        while low < high {
            guard DispatchTime.now().uptimeNanoseconds <= deadline else { return nil }
            let middle = (low + high) / 2
            visited += 1
            AXUIElementSetMessagingTimeout(children[middle], budget.messagingTimeout)
            guard let frame = read(children[middle])?.frame, !frame.isEmpty else { return nil }
            if frame.maxY <= caret.minY { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func queuedRange(count: Int, around pivot: Int?) -> Range<Int> {
        guard count > maxChildrenPerContainer else { return 0..<count }
        let start = max(0, min((pivot ?? 0) - maxChildrenPerContainer / 2, count - maxChildrenPerContainer))
        return start..<(start + maxChildrenPerContainer)
    }

    private func childPriorityFor(_ frame: CGRect, parent: CGFloat) -> CGFloat {
        guard !frame.isEmpty else { return parent }
        return max(parent, ScreenText.score(frame, caret: caret, field: field))
    }

    private func paragraphs(from fragments: [Fragment]) -> [TextChunk] {
        let ordered = fragments.sorted { $0.blockPath == $1.blockPath
            ? $0.path.lexicographicallyPrecedes($1.path)
            : $0.blockPath.lexicographicallyPrecedes($1.blockPath) }
        var chunks: [TextChunk] = []
        var current: (block: [Int], text: String, frame: CGRect, last: CGRect)?
        for fragment in ordered {
            if var open = current, open.block == fragment.blockPath, continues(open.last, fragment.frame) {
                let newLine = startsNewLine(after: open.last, fragment)
                open.text = ScreenText.join(open.text, fragment.text, newLine: newLine)
                open.frame = open.frame.union(fragment.frame)
                open.last = fragment.frame
                current = open
                continue
            }
            if let open = current { chunks.append(TextChunk(text: open.text, frame: open.frame)) }
            current = (fragment.blockPath, fragment.text, fragment.frame, fragment.frame)
        }
        if let open = current { chunks.append(TextChunk(text: open.text, frame: open.frame)) }
        return chunks
    }

    private func startsNewLine(after previous: CGRect, _ fragment: Fragment) -> Bool {
        let lineHeight = min(max(previous.height, fragment.frame.height), 40)
        let gap = fragment.frame.minY - previous.maxY
        if gap > lineHeight / 2 { return true }
        guard fragment.frame.minY >= previous.maxY - 2 else { return false }
        return previous.maxX < fragment.blockFrame.maxX - lineHeight * 2
    }

    private func continues(_ previous: CGRect, _ next: CGRect) -> Bool {
        let lineHeight = min(max(previous.height, next.height), 40)
        let gap = next.minY - previous.maxY
        return gap <= lineHeight * 1.2
    }

    private struct Info {
        var role: String
        var subrole: String
        var value: String?
        var children: [AXUIElement]
        var frame: CGRect?
    }

    private func read(_ element: AXUIElement) -> Info? {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &raw) == .success,
              let values = raw as? [AnyObject], values.count == 6,
              let role = values[0] as? String
        else { return nil }
        let children = (values[3] as? [AnyObject] ?? []).compactMap(asElement)
        var frame: CGRect?
        if let origin = point(values[4]), let size = size(values[5]) {
            frame = CGRect(origin: origin, size: size)
        }
        return Info(
            role: role, subrole: values[1] as? String ?? "", value: values[2] as? String,
            children: children, frame: frame
        )
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let info = read(element) else { return nil }
        return info.frame
    }
}

private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value
    else { return nil }
    return asElement(value)
}

private func asElement(_ value: AnyObject) -> AXUIElement? {
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

private func axValue(_ value: AnyObject, _ type: AXValueType) -> AXValue? {
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    return AXValueGetType(axValue) == type ? axValue : nil
}

private func point(_ value: AnyObject) -> CGPoint? {
    guard let axValue = axValue(value, .cgPoint) else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
}

private func size(_ value: AnyObject) -> CGSize? {
    guard let axValue = axValue(value, .cgSize) else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
}

private struct NodeHeap {
    private var items: [(node: Node, order: Int)] = []
    private var counter = 0

    mutating func push(_ node: Node) {
        items.append((node, counter))
        counter += 1
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(items[child], items[parent]) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Node? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1, right = left + 1
            var best = parent
            if left < items.count, precedes(items[left], items[best]) { best = left }
            if right < items.count, precedes(items[right], items[best]) { best = right }
            guard best != parent else { break }
            items.swapAt(parent, best)
            parent = best
        }
        return top.node
    }

    private func precedes(_ a: (node: Node, order: Int), _ b: (node: Node, order: Int)) -> Bool {
        a.node.priority == b.node.priority ? a.order < b.order : a.node.priority < b.node.priority
    }
}
