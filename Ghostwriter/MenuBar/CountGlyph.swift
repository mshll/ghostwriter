import AppKit

/// Geometry uses the units of `MenuBarIcon.svg`: 4 units per point, origin at (22, 9), y down.
enum CountGlyph {
    private static let unitsPerPoint: CGFloat = 4
    private static let origin = CGPoint(x: 22, y: 9)
    private static let cornerRadius: CGFloat = 18
    private static let hemTop: CGFloat = 64
    private static let hemBottom: CGFloat = 71.3333
    private static let bodyTop: CGFloat = 18
    private static let faintAlpha: CGFloat = 0.35
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    static func image(text: String) -> NSImage {
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let textWidth = label.size().width * unitsPerPoint
        let right = max(52.5 + textWidth + 22, 72)
        let size = NSSize(width: (right + 2 - origin.x) / unitsPerPoint, height: 18)

        let image = NSImage(size: size, flipped: true) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: 1 / unitsPerPoint)
            transform.translateX(by: -origin.x, yBy: -origin.y)
            transform.concat()

            NSColor.black.setFill()
            typedHalf().fill()
            NSColor.black.withAlphaComponent(faintAlpha).setFill()
            box(right: right).fill()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 47.5, y: 11, width: 5, height: 68), xRadius: 2.5, yRadius: 2.5).fill()

            let centerX = (52.5 + right) / 2
            let centerY = (bodyTop + hemBottom) / 2
            let baseline = centerY + font.capHeight * unitsPerPoint / 2
            transform.invert()
            transform.concat()
            let point = NSPoint(
                x: (centerX - origin.x) / unitsPerPoint - label.size().width / 2,
                y: (baseline - origin.y) / unitsPerPoint - font.ascender
            )
            label.draw(at: point)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func typedHalf() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 50, y: bodyTop))
        path.appendArc(from: NSPoint(x: 28, y: bodyTop), to: NSPoint(x: 28, y: 40), radius: 22)
        path.line(to: NSPoint(x: 28, y: hemTop))
        appendScallop(to: path, from: 28, to: 42.6667)
        path.appendArc(from: NSPoint(x: 42.6667, y: hemBottom), to: NSPoint(x: 50, y: hemBottom), radius: 7.3333)
        path.close()
        path.append(NSBezierPath(roundedRect: NSRect(x: 35, y: 33, width: 9, height: 15), xRadius: 4.5, yRadius: 4.5))
        path.windingRule = .evenOdd
        return path
    }

    private static func box(right: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 50, y: bodyTop))
        path.appendArc(from: NSPoint(x: right, y: bodyTop), to: NSPoint(x: right, y: hemBottom), radius: cornerRadius)
        path.appendArc(from: NSPoint(x: right, y: hemBottom), to: NSPoint(x: 50, y: hemBottom), radius: cornerRadius)
        path.line(to: NSPoint(x: 50, y: hemBottom))
        path.close()
        return path
    }

    private static func appendScallop(to path: NSBezierPath, from start: CGFloat, to end: CGFloat) {
        let mid = (start + end) / 2
        path.appendArc(from: NSPoint(x: start, y: hemBottom), to: NSPoint(x: mid, y: hemBottom), radius: 7.3333)
        path.appendArc(from: NSPoint(x: end, y: hemBottom), to: NSPoint(x: end, y: hemTop), radius: 7.3333)
    }
}
