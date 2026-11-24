import Capture
import Foundation
import GWCore
import Memory
import Prompting
import ScreenContext
import os

/// Context gathered once per focused field, so the prompt prefix stays byte-stable while the user types.
struct SessionContext: Sendable {
    var examples: [String] = []
    var screenText: String?
    var clipboard: String?
    var recentWindow: PromptContext.RecentWindow?
    /// The title when the context was read. The prompt uses it instead of the live title, which changes
    /// with edit markers and unread counts and would invalidate the decoded prompt.
    var windowTitle: String?
    /// The field's transcript when the context was read, to tell when a terminal agent has answered since.
    var transcript: String?
    var loadedAt = ContinuousClock.now
    var keepsDate = false
    var beforeAnchor: String?
}

struct ContextRequest {
    var snapshot: FieldSnapshot
    var exampleLimit: Int
    var includeScreen: Bool
    var includeRecentWindow: Bool
    var clipboard: String?
    var sessionKey: String?
    var screenOptions: ScreenContextOptions

    init(
        snapshot: FieldSnapshot, exampleLimit: Int, includeScreen: Bool, includeRecentWindow: Bool, allowOCR: Bool,
        clipboard: String?, sessionKey: String?
    ) {
        self.snapshot = snapshot
        self.exampleLimit = exampleLimit
        self.includeScreen = includeScreen
        self.includeRecentWindow = includeRecentWindow
        self.clipboard = clipboard
        self.sessionKey = sessionKey
        screenOptions = ScreenContextOptions()
        screenOptions.allowOCR = allowOCR
        screenOptions.language = LanguageDetector.language(ofTextBefore: snapshot.textBefore)
            ?? snapshot.language
    }

    nonisolated private static let log = Logger.gw("SessionContext")

    func load(
        memory: MemoryStore?, screen: ScreenContextProvider, recentWindows: RecentWindowTracker, builder: PromptBuilder?
    ) async -> SessionContext {
        let snapshot = snapshot
        let options = screenOptions
        async let screenText: String? = includeScreen ? Self.screenText(for: snapshot, options: options, screen: screen) : nil
        async let recentWindow = includeRecentWindow
            ? Self.recentWindow(typingIn: snapshot.app.pid, from: recentWindows, builder: builder) : nil
        let examples = await Self.examples(for: snapshot, limit: exampleLimit, excluding: sessionKey, memory: memory)
        return SessionContext(
            examples: examples,
            screenText: await screenText,
            clipboard: clipboard,
            recentWindow: await recentWindow,
            windowTitle: snapshot.windowTitle,
            transcript: snapshot.transcript
        )
    }

    private static func screenText(
        for snapshot: FieldSnapshot, options: ScreenContextOptions, screen: ScreenContextProvider
    ) async -> String? {
        guard let transcript = snapshot.transcript else { return await screen.text(for: snapshot, options: options) }
        return transcript.isEmpty ? nil : String(transcript.suffix(options.maxCharacters))
    }

    private static func recentWindow(
        typingIn pid: pid_t, from tracker: RecentWindowTracker, builder: PromptBuilder?
    ) async -> PromptContext.RecentWindow? {
        guard let window = await tracker.recent(typingIn: pid) else { return nil }
        let section = PromptContext.RecentWindow(
            appName: window.app.name, title: window.title,
            host: WindowSourceRules.host(of: window.urls, in: window.app.bundleID), text: window.text
        )
        guard let builder else { return section }
        return await fitted(section, with: builder)
    }

    @concurrent
    nonisolated private static func fitted(
        _ section: PromptContext.RecentWindow, with builder: PromptBuilder
    ) async -> PromptContext.RecentWindow {
        builder.fitted(section)
    }

    func screenTextAfterOCR(screen: ScreenContextProvider) async -> String? {
        guard includeScreen, screenOptions.allowOCR, snapshot.transcript == nil else { return nil }
        return await screen.textAfterOCR(for: snapshot, options: screenOptions)
    }

    static func examples(for snapshot: FieldSnapshot, limit: Int, excluding sessionKey: String?, memory: MemoryStore?) async -> [String] {
        guard let memory, limit > 0 else { return [] }
        let query = String(snapshot.textBefore.suffix(600))
        let field = MemoryStore.fieldText(before: snapshot.textBefore, after: snapshot.textAfter)
        let language = LanguageDetector.language(ofTextBefore: snapshot.textBefore)
        let bundleID = snapshot.app.bundleID
        return await Task.detached {
            do {
                return try memory.examples(
                    query: query, field: field, bundleID: bundleID, language: language, limit: limit, excludingKey: sessionKey
                )
            } catch {
                log.error("Fetching examples failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }.value
    }
}
