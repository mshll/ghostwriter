import AppKit
import GWCore
import SwiftUI
import os

enum PermissionTopic {
    case accessibility, screenRecording, pasteboard

    var settings: SystemSettings {
        switch self {
        case .accessibility: .accessibility
        case .screenRecording: .screenRecording
        case .pasteboard: .pasteboard
        }
    }

    var title: String {
        switch self {
        case .accessibility, .screenRecording: "Turn on Ghostwriter in the list above"
        case .pasteboard: "Set Ghostwriter to Always Allow"
        }
    }

    var detail: String {
        switch self {
        case .accessibility: "Not in the list? Drag it in from here. Setup continues by itself."
        case .screenRecording: "Not in the list? Drag it in from here. If macOS asks to quit and reopen Ghostwriter, setup picks up where you left off."
        case .pasteboard: "Under Paste from Other Apps. Ghostwriter only reads what you copy when it\u{2019}s always allowed."
        }
    }

    var takesDrag: Bool { self != .pasteboard }
}

final class PermissionGuide {
    private static let settingsBundleID = "com.apple.systempreferences"
    private static let size = CGSize(width: 620, height: 92)

    private let panel: NSPanel
    private var timer: Timer?
    private var settingsWindowNumber: Int?
    private var isGranted: () -> Bool = { false }
    var onBack: () -> Void = {}

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)
    }

    func show(_ topic: PermissionTopic, isGranted: @escaping () -> Bool) {
        self.isGranted = isGranted
        let hosting = NSHostingView(rootView: GuideBar(topic: topic, back: { [weak self] in self?.back() }))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        panel.orderOut(nil)
        settingsWindowNumber = nil
        open(topic.settings)
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // AppKit hands activation to an app opened through NSWorkspace only when this app is active, and the cover
    // takes the keyboard without activating it. Without this, an already open System Settings stays behind.
    private func open(_ settings: SystemSettings) {
        guard !NSApp.isActive else {
            settings.open()
            return
        }
        NSApp.activate()
        Task {
            for _ in 0..<10 where !NSApp.isActive {
                do {
                    try await Task.sleep(for: .milliseconds(30))
                } catch {
                    return
                }
            }
            settings.open()
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func back() {
        hide()
        onBack()
    }

    private func follow() {
        if isGranted() {
            hide()
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID,
              let window = Self.settingsWindow()
        else {
            panel.orderOut(nil)
            settingsWindowNumber = nil
            return
        }
        let target = frame(under: window.frame)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(target.offsetBy(dx: 0, dy: -14), display: false)
            panel.order(.above, relativeTo: window.number)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        } else if panel.frame.origin != target.origin {
            panel.setFrameOrigin(target.origin)
        }
        if settingsWindowNumber != window.number {
            panel.order(.above, relativeTo: window.number)
            settingsWindowNumber = window.number
        }
    }

    private func frame(under window: CGRect) -> CGRect {
        let visible = NSScreen.screens.first { $0.frame.intersects(window) }?.visibleFrame ?? window
        let sidebar = min(max(window.width * 0.29, 214), 272)
        let paneMidX = window.minX + sidebar + (window.width - sidebar) / 2
        let x = min(max(paneMidX - Self.size.width / 2, visible.minX + 16), visible.maxX - Self.size.width - 16)
        let y = max(window.minY - Self.size.height + 10, visible.minY + 12)
        return CGRect(origin: CGPoint(x: x, y: y), size: Self.size)
    }

    // Window bounds, unlike window titles, need no permission.
    private static func settingsWindow() -> (frame: CGRect, number: Int)? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.maxY
        else { return nil }
        let windows = info.compactMap { entry -> (frame: CGRect, number: Int)? in
            guard entry[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return (CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height), number)
        }
        return windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

private struct GuideBar: View {
    let topic: PermissionTopic
    let back: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            if topic.takesDrag {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OnboardingStyle.accent)
                    AppTile()
                        .frame(width: 184, height: 44)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnboardingStyle.ink)
                Text(topic.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Back", action: back)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OnboardingStyle.ink)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.09).opacity(0.96), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .padding(4)
    }
}

// Dragging carries the app's file URL, which the privacy lists accept.
private struct AppTile: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableAppTile { DraggableAppTile() }
    func updateNSView(_ nsView: DraggableAppTile, context: Context) {}
}

final class DraggableAppTile: NSView, NSDraggingSource {
    private static let log = Logger.gw("PermissionGuide")

    init() {
        super.init(frame: .zero)
        let content = NSHostingView(rootView: TileFace())
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: snapshot())
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        Self.log.info("Started dragging the app into System Settings")
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    private func snapshot() -> NSImage {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return NSApp.applicationIconImage }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

private struct TileFace: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            Text("Ghostwriter")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(OnboardingStyle.ink)
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OnboardingStyle.muted)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OnboardingStyle.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
