import Actions
import AppKit
import SwiftUI

/// The panel is non-activating: the host app stays the active app and keeps its selection while the
/// panel takes keyboard input. On Replace the panel closes first and `onReplace` runs about 80 ms later,
/// once key focus is back in the host window; the caller then inserts the text there (typing or pasting
/// over the still-selected range replaces it).
final class SelectionActionsController: NSObject, NSWindowDelegate {
    private static let replaceDelay = Duration.milliseconds(80)
    private static let gap: CGFloat = 8
    /// Keeps the toolbar clear of the I-beam pointer, which reaches about this far around its hot spot.
    private static let pointerClearance: CGFloat = 12

    private let preferences: Preferences
    private let assistant: WritingAssistant
    private var panel: SelectionActionsPanel?
    private var model: SelectionActionsModel?
    private var onReplace: ((String) -> Void)?

    init(preferences: Preferences, assistant: WritingAssistant) {
        self.preferences = preferences
        self.assistant = assistant
    }

    var isPresented: Bool { panel != nil }

    var isPassive: Bool { panel.map { !$0.isKeyWindow } ?? false }

    private(set) var presentedText: String?

    /// - Parameters:
    ///   - rect: Selection bounds in global screen coordinates with a top-left origin (the Accessibility convention). `.zero` places the panel at the mouse.
    func present(
        selectedText: String, near rect: CGRect, surroundingText: String = "", takesFocus: Bool = true,
        onReplace: @escaping (String) -> Void
    ) {
        dismiss()
        let actions = WritingAction.allCases.filter { preferences.enabledActions.contains($0) }
        let model = SelectionActionsModel(
            selectedText: selectedText, surroundingText: surroundingText, actions: actions,
            targetLanguage: preferences.translateTargetLanguage, assistant: assistant,
            onTargetLanguageChange: { [preferences] in preferences.translateTargetLanguage = $0 }
        )
        let (frame, placement) = Self.layout(near: rect)
        let view = SelectionActionsView(
            model: model,
            placement: placement,
            replace: { [weak self] in self?.replace(with: $0) },
            copy: { [weak self] in self?.copy($0) },
            close: { [weak self] in self?.dismiss() }
        )
        let hostingView = FirstClickHostingView(rootView: view)
        hostingView.sizingOptions = []
        let panel = SelectionActionsPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        self.panel = panel
        self.model = model
        self.onReplace = onReplace
        presentedText = selectedText
        if takesFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        model?.cancel()
        model = nil
        onReplace = nil
        presentedText = nil
        panel.delegate = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func replace(with text: String) {
        let handler = onReplace
        dismiss()
        Task {
            do {
                try await Task.sleep(for: Self.replaceDelay)
            } catch {
                return
            }
            handler?(text)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        dismiss()
    }

    private static func layout(near axRect: CGRect) -> (CGRect, SelectionActionsPlacement) {
        let size = SelectionActionsView.canvasSize
        let target = axRect == .zero ? pointerRect() : cocoaRect(fromAX: axRect)
        let screen = NSScreen.screens.first { $0.frame.intersects(target.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? target.insetBy(dx: -size.width, dy: -size.height)
        let insets = SelectionActionsView.contentInsets
        let x = min(max(target.minX - insets.leading, visible.minX), visible.maxX - size.width)
        let below = target.minY + insets.top - gap - size.height
        if below >= visible.minY {
            return (CGRect(origin: CGPoint(x: x, y: below), size: size), .below)
        }
        let above = min(target.maxY - insets.bottom + gap, visible.maxY - size.height)
        return (CGRect(origin: CGPoint(x: x, y: above), size: size), .above)
    }

    private static func pointerRect() -> CGRect {
        let pointer = NSEvent.mouseLocation
        return CGRect(x: pointer.x, y: pointer.y - pointerClearance, width: 0, height: 2 * pointerClearance)
    }

    private static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

private final class SelectionActionsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
