import AppKit

final class GhostTextView: NSView {
    private var text = NSAttributedString()
    private var textRect = CGRect.zero
    private var clip = CGRect.zero
    private var backdrop: GhostBackdrop?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func update(text: NSAttributedString, in rect: CGRect, clip: CGRect, backdrop: GhostBackdrop?) {
        guard rect != textRect || clip != self.clip || backdrop != self.backdrop || !text.isEqual(to: self.text)
        else { return }
        self.text = text
        textRect = rect
        self.clip = clip
        self.backdrop = backdrop
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let backdrop {
            backdrop.color.setFill()
            backdrop.rect.fill()
        }
        clip.clip()
        text.draw(with: textRect, options: [.usesLineFragmentOrigin])
    }
}

final class PickerListView: NSView {
    static let rowHeight: CGFloat = 24
    static let outerInset: CGFloat = 5
    static let rowPadding: CGFloat = 8
    static let badgeSize: CGFloat = 16
    static let badgeGap: CGFloat = 8
    static let detailGap: CGFloat = 6
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 420

    private var items: [(title: String, detail: String?)] = []
    private(set) var highlightedIndex = 0
    private var onSelect: (@MainActor (Int) -> Void)?
    private let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    override var isFlipped: Bool { true }

    static var titleInset: CGFloat { outerInset + rowPadding + badgeSize + badgeGap }

    func configure(_ items: [(title: String, detail: String?)], onSelect: @escaping @MainActor (Int) -> Void) {
        self.items = items
        self.onSelect = onSelect
        highlightedIndex = 0
        needsDisplay = true
    }

    func highlight(_ index: Int) {
        guard items.indices.contains(index), index != highlightedIndex else { return }
        highlightedIndex = index
        needsDisplay = true
    }

    var preferredSize: CGSize {
        let widest = items.map { item in
            var width = titleWidth(item.title)
            if let detail = item.detail { width += Self.detailGap + titleWidth(detail) }
            return width
        }.max() ?? 0
        let width = Self.titleInset + widest + Self.rowPadding + Self.outerInset
        return CGSize(
            width: min(max(width.rounded(.up), Self.minWidth), Self.maxWidth),
            height: CGFloat(items.count) * Self.rowHeight + 2 * Self.outerInset
        )
    }

    private func titleWidth(_ string: String) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: titleFont]).size().width
    }

    private func rowRect(_ index: Int) -> CGRect {
        CGRect(
            x: Self.outerInset,
            y: Self.outerInset + CGFloat(index) * Self.rowHeight,
            width: bounds.width - 2 * Self.outerInset,
            height: Self.rowHeight
        )
    }

    private func row(at point: CGPoint) -> Int? {
        items.indices.first { rowRect($0).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, item) in items.enumerated() {
            let rect = rowRect(index)
            let isHighlighted = index == highlightedIndex
            if isHighlighted {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            let primary: NSColor = isHighlighted ? .alternateSelectedControlTextColor : .labelColor
            let secondary: NSColor = isHighlighted
                ? .alternateSelectedControlTextColor.withAlphaComponent(0.75)
                : .secondaryLabelColor

            let badge = CGRect(
                x: rect.minX + Self.rowPadding,
                y: rect.midY - Self.badgeSize / 2,
                width: Self.badgeSize,
                height: Self.badgeSize
            )
            (isHighlighted ? NSColor.white.withAlphaComponent(0.25) : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            let number = NSAttributedString(
                string: "\(index + 1)",
                attributes: [.font: badgeFont, .foregroundColor: isHighlighted ? primary : NSColor.secondaryLabelColor]
            )
            let numberSize = number.size()
            number.draw(at: CGPoint(x: badge.midX - numberSize.width / 2, y: badge.midY - numberSize.height / 2))

            let line = NSMutableAttributedString(
                string: item.title,
                attributes: [.font: titleFont, .foregroundColor: primary]
            )
            if let detail = item.detail {
                line.append(NSAttributedString(string: "\u{2002}" + detail, attributes: [.font: titleFont, .foregroundColor: secondary]))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            let lineHeight = line.size().height
            let textX = rect.minX + Self.rowPadding + Self.badgeSize + Self.badgeGap
            line.draw(
                with: CGRect(x: textX, y: rect.midY - lineHeight / 2, width: rect.maxX - Self.rowPadding - textX, height: lineHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let index = row(at: convert(event.locationInWindow, from: nil)) else { return }
        highlight(index)
        onSelect?(index)
    }

    override func mouseMoved(with event: NSEvent) {
        if let index = row(at: convert(event.locationInWindow, from: nil)) {
            highlight(index)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}
