import AppKit
import GWCore

/// Geometry in global top-left screen coordinates, like AX; `word` and `chip` are relative to `frame`.
struct TypoPlacement: Equatable {
    var frame: CGRect
    var word: CGRect
    var chip: CGRect
}

enum MarkLayout {
    static let statusGap: CGFloat = 6
    static let chipGap: CGFloat = 2

    static func status(size: CGSize, caret: CGRect, screen: CGRect) -> CGRect {
        var y = caret.maxY + statusGap
        if y + size.height > screen.maxY { y = caret.minY - statusGap - size.height }
        let x = min(max(caret.minX - 4, screen.minX), screen.maxX - size.width)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func typo(
        caret: CGRect, wordWidth: CGFloat, closingWidth: CGFloat, chipWidth: CGFloat, direction: WritingDirection
    ) -> TypoPlacement {
        let word: CGRect
        let chip: CGRect
        switch direction {
        case .leftToRight:
            word = CGRect(x: caret.minX - closingWidth - wordWidth, y: caret.minY, width: wordWidth, height: caret.height)
            chip = CGRect(x: caret.minX + chipGap, y: caret.minY, width: chipWidth, height: caret.height)
        case .rightToLeft:
            word = CGRect(x: caret.minX + closingWidth, y: caret.minY, width: wordWidth, height: caret.height)
            chip = CGRect(x: caret.minX - chipGap - chipWidth, y: caret.minY, width: chipWidth, height: caret.height)
        }
        let frame = word.union(chip)
        return TypoPlacement(
            frame: frame,
            word: word.offsetBy(dx: -frame.minX, dy: -frame.minY),
            chip: chip.offsetBy(dx: -frame.minX, dy: -frame.minY)
        )
    }
}

final class StatusPillView: NSView {
    static let height: CGFloat = 22
    private static let padding: CGFloat = 9
    private static let spinnerSize: CGFloat = 10
    private static let gap: CGFloat = 6

    private let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private let spinner = NSProgressIndicator()
    private var text = NSAttributedString()
    private var busy = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 0.5
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func configure(text: String, detail: String?, busy: Bool) {
        let string = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        if let detail {
            string.append(NSAttributedString(
                string: " · " + detail,
                attributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.6)]
            ))
        }
        self.text = string
        self.busy = busy
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        needsLayout = true
        needsDisplay = true
    }

    var preferredSize: CGSize {
        let spinnerWidth = busy ? Self.spinnerSize + Self.gap : 0
        return CGSize(width: ceil(text.size().width + spinnerWidth + 2 * Self.padding), height: Self.height)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        spinner.frame = CGRect(
            x: Self.padding, y: (bounds.height - Self.spinnerSize) / 2, width: Self.spinnerSize, height: Self.spinnerSize
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let x = Self.padding + (busy ? Self.spinnerSize + Self.gap : 0)
        let size = text.size()
        text.draw(at: CGPoint(x: x, y: (bounds.height - size.height) / 2))
    }
}

final class TypoMarkView: NSView {
    static let chipPadding: CGFloat = 4
    static let correctionColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemGreen
            : NSColor(srgbRed: 0.1, green: 0.5, blue: 0.22, alpha: 1)
    }

    private var word = CGRect.zero
    private var chip = CGRect.zero
    private var correction = NSAttributedString()

    override var isFlipped: Bool { true }

    func update(word: CGRect, chip: CGRect, correction: NSAttributedString) {
        self.word = word
        self.chip = chip
        self.correction = correction
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let word = self.word.insetBy(dx: -1, dy: 1)
        NSColor.systemRed.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: word, xRadius: 2, yRadius: 2).fill()
        NSColor.systemRed.setFill()
        CGRect(x: word.minX, y: word.midY - 1, width: word.width, height: 2).fill()
        let chip = self.chip.insetBy(dx: 0, dy: 1)
        NSColor.systemGreen.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        let size = correction.size()
        correction.draw(at: CGPoint(x: chip.minX + Self.chipPadding, y: chip.midY - size.height / 2))
    }
}
