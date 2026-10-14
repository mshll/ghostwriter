import AppKit
import GWCore
import QuartzCore

/// Geometry in and out is in global top-left screen coordinates, like AX.
@MainActor
public final class GhostOverlay {
    public var appearance = OverlayAppearance()

    private var ghostPanel: OverlayPanel?
    let ghostView = GhostTextView()
    private var pickerPanel: OverlayPanel?
    private let pickerView = PickerListView()
    private var typoPanel: OverlayPanel?
    private let typoView = TypoMarkView()
    private var statusPanel: OverlayPanel?
    private let statusView = StatusPillView()
    private let fonts = FontCache()
    private let backgrounds = BackgroundSampler()
    private var lastShown: (text: String, snapshot: FieldSnapshot, multiline: Bool)?
    private static let fadeInDuration: CFTimeInterval = 0.06
    private static let fadeKey = "fadeIn"

    public init() {
        backgrounds.onSample = { [weak self] id in
            guard let self, let last = self.lastShown, last.snapshot.id == id, self.isVisible else { return }
            self.show(last.text, for: last.snapshot, multiline: last.multiline)
        }
    }

    public func prepareBackground(for snapshot: FieldSnapshot) {
        backgrounds.sample(snapshot, after: .milliseconds(400))
    }

    public var isVisible: Bool { ghostPanel?.isVisible ?? false }

    public var isPickerVisible: Bool { pickerPanel?.isVisible ?? false }

    @discardableResult
    public func show(_ text: String, for snapshot: FieldSnapshot, multiline: Bool = false) -> Bool {
        let caret = snapshot.caretRect
        guard !text.isEmpty, Self.isPlaceable(caret),
              let primaryHeight = ScreenGeometry.primaryHeight,
              let screen = ScreenGeometry.screenFrame(containing: CGPoint(x: caret.minX, y: caret.midY), visible: false)
        else {
            hide()
            return false
        }
        let font = fonts.font(for: snapshot.style, caretHeight: caret.height)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font.font,
            .foregroundColor: Self.ghostColor(snapshot.style, appearance: appearance),
        ]
        let wraps = multiline || GhostLayout.runsPastLineEnd(text, snapshot: snapshot, screen: screen, font: font.font)
        let placed = wraps
            ? multilineText(text, snapshot: snapshot, screen: screen, font: font, attributes: attributes)
            : singleLineText(text, snapshot: snapshot, screen: screen, font: font, attributes: attributes)
        guard let (string, placement) = placed else {
            hide()
            return false
        }
        typoPanel?.orderOut(nil)
        let panel = ghostPanel ?? makeGhostPanel()
        let frame = placement.frame.flippedVertically(primaryScreenHeight: primaryHeight)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        ghostView.update(text: string, in: placement.textRect, clip: placement.textClip, backdrop: placement.backdrop)
        if !panel.isVisible {
            reveal(panel, fading: ghostView)
        }
        lastShown = (text, snapshot, multiline)
        return true
    }

    public func hide() {
        lastShown = nil
        typoPanel?.orderOut(nil)
        guard let ghostPanel, ghostPanel.isVisible else { return }
        ghostView.layer?.removeAnimation(forKey: Self.fadeKey)
        ghostPanel.orderOut(nil)
    }

    /// Strikes through `word`, which ends `closing` before the caret, and shows `correction` in a chip at the caret.
    @discardableResult
    public func showTypoFix(word: String, closing: String, correction: String, for snapshot: FieldSnapshot) -> Bool {
        let caret = snapshot.caretRect
        guard Self.isPlaceable(caret), let primaryHeight = ScreenGeometry.primaryHeight else {
            hide()
            return false
        }
        let font = fonts.font(for: snapshot.style, caretHeight: caret.height).font
        let label = NSAttributedString(string: correction, attributes: [.font: font, .foregroundColor: TypoMarkView.correctionColor])
        let placement = MarkLayout.typo(
            caret: caret,
            wordWidth: GhostLayout.textWidth(word, font: font),
            closingWidth: GhostLayout.textWidth(closing, font: font),
            chipWidth: ceil(label.size().width) + 2 * TypoMarkView.chipPadding,
            direction: snapshot.direction
        )
        lastShown = nil
        ghostPanel?.orderOut(nil)
        let panel = typoPanel ?? makeTypoPanel()
        panel.setFrame(placement.frame.flippedVertically(primaryScreenHeight: primaryHeight), display: false)
        typoView.frame = panel.contentView?.bounds ?? .zero
        typoView.update(word: placement.word, chip: placement.chip, correction: label)
        if !panel.isVisible {
            reveal(panel, fading: typoView)
        }
        return true
    }

    @discardableResult
    public func showStatus(_ text: String, detail: String? = nil, busy: Bool = false, near caret: CGRect) -> Bool {
        guard Self.isPlaceable(caret), let primaryHeight = ScreenGeometry.primaryHeight,
              let screen = ScreenGeometry.screenFrame(containing: CGPoint(x: caret.minX, y: caret.midY), visible: true)
        else {
            hideStatus()
            return false
        }
        statusView.configure(text: text, detail: detail, busy: busy)
        let frame = MarkLayout.status(size: statusView.preferredSize, caret: caret, screen: screen)
        let panel = statusPanel ?? makeStatusPanel()
        panel.setFrame(frame.flippedVertically(primaryScreenHeight: primaryHeight), display: true)
        statusView.frame = panel.contentView?.bounds ?? .zero
        if !panel.isVisible {
            reveal(panel, fading: statusView)
        }
        return true
    }

    public func hideStatus() {
        guard let statusPanel, statusPanel.isVisible else { return }
        statusView.layer?.removeAnimation(forKey: Self.fadeKey)
        statusPanel.orderOut(nil)
    }

    @discardableResult
    public func showPicker(
        _ items: [PickerItem], near caretRect: CGRect, onSelect: @escaping @MainActor (Int) -> Void
    ) -> Bool {
        let rows = items.prefix(9).map { (title: $0.title, detail: $0.detail) }
        guard !rows.isEmpty, Self.isPlaceable(caretRect),
              let primaryHeight = ScreenGeometry.primaryHeight,
              let screen = ScreenGeometry.screenFrame(containing: CGPoint(x: caretRect.minX, y: caretRect.midY), visible: true)
        else {
            hidePicker()
            return false
        }
        pickerView.configure(rows, onSelect: onSelect)
        let frame = PickerLayout.frame(
            size: pickerView.preferredSize,
            caret: caretRect,
            screen: screen,
            titleInset: PickerListView.titleInset
        )
        let panel = pickerPanel ?? makePickerPanel()
        panel.setFrame(frame.flippedVertically(primaryScreenHeight: primaryHeight), display: true)
        pickerView.frame = panel.contentView?.bounds ?? .zero
        panel.invalidateShadow()
        if !panel.isVisible, let content = panel.contentView {
            reveal(panel, fading: content)
        }
        return true
    }

    public func highlightPickerRow(_ index: Int) {
        pickerView.highlight(index)
    }

    public func hidePicker() {
        guard let pickerPanel, pickerPanel.isVisible else { return }
        pickerPanel.contentView?.layer?.removeAnimation(forKey: Self.fadeKey)
        pickerPanel.orderOut(nil)
    }

    /// Capture reports a zero rect when it found no caret; drawn as is, it lands at the screen's corner.
    private static func isPlaceable(_ caret: CGRect) -> Bool {
        caret.height > 0 && caret.minX.isFinite && caret.minY.isFinite && caret.origin != .zero
    }

    private func singleLineText(
        _ text: String,
        snapshot: FieldSnapshot,
        screen: CGRect,
        font: GhostFont,
        attributes: [NSAttributedString.Key: Any]
    ) -> (NSAttributedString, GhostPlacement)? {
        guard var placement = GhostLayout.singleLine(
            caret: snapshot.caretRect,
            field: snapshot.fieldFrame,
            screen: screen,
            direction: snapshot.direction,
            font: font
        ) else { return nil }
        var attributes = attributes
        attributes[.paragraphStyle] = GhostLayout.singleLineParagraph(snapshot.direction)
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        let range = placement.frame.minX...placement.frame.maxX
        guard let rest = GhostLayout.restOfLine(
            snapshot,
            range: range,
            font: font.font,
            suggestionWidth: GhostLayout.textWidth(text, font: font.font)
        ) else { return (string, placement) }
        let (backdrop, hostColor) = pushAside(snapshot, restWidth: rest.hiddenWidth, placement: placement, font: font)
        attributes[.foregroundColor] = hostColor
        string.append(NSAttributedString(string: rest.pushed, attributes: attributes))
        placement.backdrop = backdrop
        return (string, placement)
    }

    private func pushAside(
        _ snapshot: FieldSnapshot,
        restWidth: CGFloat,
        placement: GhostPlacement,
        font: GhostFont
    ) -> (GhostBackdrop, hostColor: NSColor) {
        backgrounds.sample(snapshot)
        let background = backgrounds.color(for: snapshot).map(Self.nsColor) ?? Self.fallbackBackground
        let rect = GhostLayout.backdropRect(
            caret: snapshot.caretRect,
            frame: placement.frame,
            restWidth: restWidth,
            clip: placement.textClip,
            direction: snapshot.direction,
            font: font
        )
        return (GhostBackdrop(rect: rect, color: background), Self.hostTextColor(snapshot.style, background: background))
    }

    /// Native text views draw on the text background colour; used until a screen sample arrives.
    private static var fallbackBackground: NSColor {
        NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .textBackgroundColor
    }

    private static func nsColor(_ color: RGBAColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    static func hostTextColor(_ style: FieldStyle, background: NSColor) -> NSColor {
        if let color = style.textColor { return nsColor(color) }
        let rgb = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return NSColor(white: luminance > 0.5 ? 0 : 1, alpha: 1)
    }

    private func multilineText(
        _ text: String,
        snapshot: FieldSnapshot,
        screen: CGRect,
        font: GhostFont,
        attributes: [NSAttributedString.Key: Any]
    ) -> (NSAttributedString, GhostPlacement)? {
        let caret = snapshot.caretRect
        guard let range = GhostLayout.horizontalRange(
            caret: caret,
            field: snapshot.fieldFrame,
            screen: screen,
            direction: snapshot.direction
        ) else { return nil }
        let inset = GhostLayout.lineStartInset(snapshot, range: range, font: font.font)
        let paragraph = GhostLayout.multilineParagraph(
            caret: caret,
            range: range,
            inset: inset,
            direction: snapshot.direction,
            font: font
        )
        let width = range.upperBound - range.lowerBound
        let firstLineRoom = width - paragraph.firstLineHeadIndent + paragraph.tailIndent
        let ghost = GhostLayout.wrappingFirstWord(text, font: font.font, room: firstLineRoom)
        let rest = GhostLayout.restOfLine(snapshot, range: range, font: font.font, suggestionWidth: 0)
        let pushed = rest?.pushed ?? ""
        let string = NSMutableAttributedString(
            attributedString: GhostLayout.multilineString(ghost + pushed, attributes: attributes, paragraph: paragraph)
        )
        let height = string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
        guard var placement = GhostLayout.multiline(caret: caret, range: range, screen: screen, font: font, textHeight: height)
        else { return nil }
        if let rest {
            let (backdrop, hostColor) = pushAside(snapshot, restWidth: rest.hiddenWidth, placement: placement, font: font)
            let pushedLength = (pushed as NSString).length
            string.addAttribute(
                .foregroundColor,
                value: hostColor,
                range: NSRange(location: string.length - pushedLength, length: pushedLength)
            )
            placement.backdrop = backdrop
        }
        return (string, placement)
    }

    static func ghostColor(_ style: FieldStyle, appearance: OverlayAppearance) -> NSColor {
        guard appearance.useFieldColor, let color = style.textColor else {
            return NSColor.textColor.withAlphaComponent(appearance.opacity)
        }
        return NSColor(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha * appearance.opacity
        )
    }

    private func reveal(_ panel: NSPanel, fading view: NSView) {
        panel.orderFrontRegardless()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.fadeInDuration
        layer.add(fade, forKey: Self.fadeKey)
    }

    private func makeGhostPanel() -> OverlayPanel {
        let panel = OverlayPanel(acceptsMouse: false)
        panel.contentView = ghostView
        ghostPanel = panel
        return panel
    }

    private func makeTypoPanel() -> OverlayPanel {
        let panel = OverlayPanel(acceptsMouse: false)
        panel.contentView = typoView
        typoPanel = panel
        return panel
    }

    private func makeStatusPanel() -> OverlayPanel {
        let panel = OverlayPanel(acceptsMouse: false)
        panel.contentView = statusView
        statusPanel = panel
        return panel
    }

    private func makePickerPanel() -> OverlayPanel {
        let panel = OverlayPanel(acceptsMouse: true)
        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.pickerCornerRadius)
        pickerView.autoresizingMask = [.width, .height]
        background.addSubview(pickerView)
        panel.contentView = background
        pickerPanel = panel
        return panel
    }

    private static let pickerCornerRadius: CGFloat = 10

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
