import Foundation
import GWCore
import os

/// Reads each window once as the user leaves it and keeps the last one that had text, for prompts in other windows.
@MainActor
public final class RecentWindowTracker {
    /// A read still running after this is left out of the context being loaded, so the first suggestion in the
    /// new field does not wait for it.
    static let waitLimitMs = 300

    public var isEnabled: () -> Bool = { false }
    /// Whether a window of this app may be read: its rules, a pause, Ghostwriter itself.
    public var mayRead: (AppIdentity) -> Bool = { _ in false }
    /// Whether the pages a window of this app shows may be read: site rules.
    public var allowsPages: (AppIdentity, [URL]) -> Bool = { _, _ in false }

    private let screen: ScreenContextProvider
    private let logger = Logger.gw("RecentWindow")
    private var current: (app: AppIdentity, window: WindowHandle)?
    private var stored: RecentWindow?
    private var work: Task<Void, Never>?
    private var expiry: Task<Void, Never>?

    public init(screen: ScreenContextProvider) {
        self.screen = screen
    }

    /// `app` came to the front, or another of its windows took focus.
    public func entered(_ app: AppIdentity) {
        guard isEnabled() else { return reset() }
        let previous = work
        work = Task {
            await previous?.value
            await arrive(in: app)
        }
    }

    public func reset() {
        current = nil
        drop()
    }

    public func recent(typingIn pid: pid_t) async -> RecentWindow? {
        guard isEnabled() else {
            drop()
            return nil
        }
        if let work, await Deadline.run(within: .milliseconds(Self.waitLimitMs), { await work.value }) == nil {
            logger.info("Left window: still reading after \(Self.waitLimitMs, privacy: .public) ms, left out")
        }
        let typing = current?.app.pid == pid ? current?.window : await WindowHandle.front(of: pid)
        return RecentWindow.select(stored, enabled: true, typingIn: typing, at: .now)
    }

    private func arrive(in app: AppIdentity) async {
        guard let window = await WindowHandle.front(of: app.pid) else { return }
        guard let left = current, left.window != window else {
            current = (app, window)
            return
        }
        current = (app, window)
        guard mayRead(left.app) else { return logger.info("Left window: skipped by its app's rules") }
        var leftWindow = left.window
        if left.app.pid != app.pid, let front = await WindowHandle.front(of: left.app.pid) { leftWindow = front }
        guard let capture = await screen.capture(leftWindow, appName: left.app.name) else {
            return logger.info("Left window: not readable")
        }
        guard allowsPages(left.app, capture.urls) else { return logger.info("Left window: skipped by site rules") }
        logger.info("\(capture.summary, privacy: .public)")
        guard let text = capture.text, isEnabled() else { return }
        stored = RecentWindow(
            window: leftWindow, app: left.app, title: capture.title, urls: capture.urls, text: text,
            capturedAt: .now
        )
        expiry?.cancel()
        expiry = Task {
            do {
                try await Task.sleep(for: RecentWindow.maxAge)
            } catch {
                return
            }
            stored = nil
        }
    }

    private func drop() {
        stored = nil
        expiry?.cancel()
        expiry = nil
    }
}
