import ApplicationServices
import CoreGraphics
import Foundation
import GWCore

/// A window, compared by its accessibility element: two windows of one app with the same frame stay different.
public struct WindowHandle: @unchecked Sendable, Equatable {
    let element: AXUIElement
    public let pid: pid_t

    init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.pid = pid
    }

    /// The app's focused window, or its main window. Both stay readable after the app leaves the front.
    public static func front(of pid: pid_t) async -> WindowHandle? {
        await AXWindowReader.frontWindow(of: pid)
    }

    public static func == (lhs: WindowHandle, rhs: WindowHandle) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element)
    }
}

/// What one read of a window found. `summary` has counts and timings only, never screen text.
public struct WindowCapture: Sendable {
    public var title: String?
    public var urls: [URL]
    public var text: String?
    public var summary: String
}

/// The text of the last window the user left that yielded any.
public struct RecentWindow: Sendable {
    public static let maxAge: Duration = .seconds(600)
    public static let maxCharacters = 2000

    public var window: WindowHandle
    public var app: AppIdentity
    public var title: String?
    public var urls: [URL]
    public var text: String
    public var capturedAt: ContinuousClock.Instant

    public init(
        window: WindowHandle, app: AppIdentity, title: String?, urls: [URL], text: String,
        capturedAt: ContinuousClock.Instant
    ) {
        self.window = window
        self.app = app
        self.title = title
        self.urls = urls
        self.text = text
        self.capturedAt = capturedAt
    }

    /// The entry the prompt may use for a field in `typingWindow`: recent, and from another window.
    public static func select(
        _ stored: RecentWindow?, enabled: Bool, typingIn typingWindow: WindowHandle?, at now: ContinuousClock.Instant
    ) -> RecentWindow? {
        guard enabled, let stored, now - stored.capturedAt <= maxAge, stored.window != typingWindow else { return nil }
        return stored
    }
}

enum RecentWindowText {
    /// Paragraphs from the top of the window down, without its title or app name, cut at `maxCharacters`.
    static func render(_ chunks: [TextChunk], title: String?, appName: String, maxCharacters: Int) -> String? {
        let titles = [title, appName].compactMap { $0.map(ScreenText.normalized) }.filter { !$0.isEmpty }
        let top = chunks.map(\.frame.minY).min() ?? 0
        let anchor = CGRect(x: chunks.map(\.frame.minX).min() ?? 0, y: top - 1, width: 1, height: 1)
        var seen: Set<String> = []
        var picked: [String] = []
        var remaining = maxCharacters
        for chunk in ScreenText.readingOrder(chunks, caret: anchor) where remaining > 0 {
            guard let text = ScreenText.cleaned(chunk.text) else { continue }
            let key = ScreenText.normalized(text)
            if titles.contains(where: { key.contains($0) && key.count <= $0.count + 6 }) { continue }
            guard seen.insert(key).inserted else { continue }
            let fitted = ScreenText.fit(text, into: remaining, keepEnd: false)
            guard !fitted.isEmpty else { break }
            picked.append(fitted)
            remaining -= fitted.count + 1
        }
        return picked.isEmpty ? nil : picked.joined(separator: "\n")
    }
}
