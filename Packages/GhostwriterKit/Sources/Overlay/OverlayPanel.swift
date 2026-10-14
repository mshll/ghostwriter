import AppKit

final class OverlayPanel: NSPanel {
    init(acceptsMouse: Bool) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = acceptsMouse
        ignoresMouseEvents = !acceptsMouse
        acceptsMouseMovedEvents = acceptsMouse
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.helpWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension CGRect {
    func flippedVertically(primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: minX, y: primaryScreenHeight - maxY, width: width, height: height)
    }
}

@MainActor
enum ScreenGeometry {
    static var primaryHeight: CGFloat? {
        NSScreen.screens.first?.frame.height
    }

    static func screenFrame(containing point: CGPoint, visible: Bool) -> CGRect? {
        guard let primaryHeight else { return nil }
        let frames = NSScreen.screens.map {
            (visible ? $0.visibleFrame : $0.frame).flippedVertically(primaryScreenHeight: primaryHeight)
        }
        let full = NSScreen.screens.map { $0.frame.flippedVertically(primaryScreenHeight: primaryHeight) }
        let index = full.firstIndex { $0.contains(point) }
            ?? full.indices.min { distance(point, full[$0]) < distance(point, full[$1]) }
        return index.map { frames[$0] }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
