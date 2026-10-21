import AppKit
import Capture
import Carbon.HIToolbox
import Input
import ScreenContext
import SpriteKit
import SwiftUI

final class OnboardingController {
    private let window: OnboardingWindow
    private let veil: NSView
    private let letters: SKView
    private let scene: LetterFallScene?
    private let preferences: Preferences
    private let statusItemFrame: () -> NSRect?
    private let guide = PermissionGuide()
    let model: OnboardingModel
    var onClose: () -> Void = {}

    init(model: OnboardingModel, preferences: Preferences, statusItemFrame: @escaping () -> NSRect?, content: some View) {
        self.model = model
        self.preferences = preferences
        self.statusItemFrame = statusItemFrame
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = OnboardingWindow(frame: frame)

        let bounds = NSRect(origin: .zero, size: frame.size)
        let container = NSView(frame: bounds)
        container.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        let tint = NSView(frame: bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.047, alpha: 0.82).cgColor
        veil = NSView(frame: bounds)
        veil.alphaValue = 0
        for view in [blur, tint] {
            view.autoresizingMask = [.width, .height]
            veil.addSubview(view)
        }

        letters = SKView(frame: bounds)
        letters.allowsTransparency = true
        scene = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : LetterFallScene(size: frame.size)
        if let scene { letters.presentScene(scene) }

        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = bounds

        for view in [veil, letters, hosting] {
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        window.contentView = container
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        model.onDropWord = { [weak self] word in self?.scene?.drop(word: word) }
        model.onFinish = { [weak self] in self?.leave() }
        model.onBringToFront = { [weak self] in self?.bringToFront() }
        model.onGuide = { [weak self] topic in self?.showGuide(topic) }
        guide.onBack = { [weak self] in self?.bringToFront() }
        model.onStepChange = { [weak self] step in
            self?.guide.hide()
            if step != .welcome { self?.preferences.onboardingStep = step }
            self?.scene?.run(.fadeAlpha(to: step.dimsLetters ? 0.35 : 1, duration: 0.5))
            // Suggestions follow the frontmost app. By now the user has typed into the cover, so macOS lets it activate.
            if step == .practice { NSApp.activate() }
        }
    }

    func present() {
        bringToFront()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            veil.animator().alphaValue = 1
        }
        scene?.rain()
        model.start()
    }

    func bringToFront() {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func showGuide(_ topic: PermissionTopic) {
        guide.show(topic) {
            switch topic {
            case .accessibility: AccessibilityPermission.isGranted
            case .screenRecording: ScreenRecordingPermission.isAllowedInSettings
            case .pasteboard: ClipboardReader.accessAllowed
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if model.isLeaving { return true }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if Int(event.keyCode) == kVK_Escape, flags.isEmpty, model.step != .practice {
            model.escape()
            return true
        }
        let isReturn = flags.isEmpty && [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode))
        if isReturn, !model.step.acceptsWithKeys, model.step != .practice {
            let editor = window.firstResponder as? NSTextView
            guard editor == nil || editor?.isFieldEditor == true else { return false }
            model.primaryAction()
            return true
        }
        if model.step.acceptsWithKeys {
            let key = HotKey(event: event)
            let isWord = key == preferences.acceptWordKey
            let isAll = key == preferences.acceptFullKey
            guard isReturn || isWord || isAll else { return false }
            if model.headlineComplete {
                model.advance()
            } else if isWord {
                model.acceptWord(key: preferences.acceptWordKey.displayName)
            } else if isAll {
                model.acceptAll(key: preferences.acceptFullKey.displayName)
            } else {
                model.completeHeadline(thenAdvance: true)
            }
            return true
        }
        return false
    }

    private func leave() {
        if let frame = statusItemFrame() {
            let screen = window.frame
            model.statusItemFrame = CGRect(x: frame.minX - screen.minX, y: screen.maxY - frame.maxY,
                                           width: frame.width, height: frame.height)
        }
        Task {
            do {
                try await Task.sleep(for: .milliseconds(200))
                scene?.openFloor()
                try await Task.sleep(for: .milliseconds(250))
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.8
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    veil.animator().alphaValue = 0
                }, completionHandler: nil)
                try await Task.sleep(for: .milliseconds(model.statusItemFrame == nil ? 900 : 2300))
            } catch {
                return
            }
            close()
        }
    }

    private func close() {
        guide.hide()
        letters.isPaused = true
        window.orderOut(nil)
        onClose()
    }
}

// Non-activating, yet it takes the keyboard: a menu bar app launched in the background is not activated, and macOS may ignore its activation request.
final class OnboardingWindow: NSPanel {
    static let coverLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    var onKey: ((NSEvent) -> Bool)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = Self.coverLevel
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        // The hosting view sits inside a container, which hides SwiftUI's fields from the default key view loop.
        autorecalculatesKeyViewLoop = true
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        level = Self.coverLevel
    }

    // Another app taking the keyboard, System Settings above all, must be able to come in front. One of
    // Ghostwriter's own panels, such as selection actions, must not lower the cover.
    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            if NSApp.keyWindow == nil { self?.level = .normal }
        }
    }

    // AppKit keeps windows below the menu bar; the cover has to sit over it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}
