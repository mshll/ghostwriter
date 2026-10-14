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
    /// The title when the context was read. The prompt uses it instead of the live title, which changes
    /// with edit markers and unread counts and would invalidate the decoded prompt.
    var windowTitle: String?
    var loadedAt = ContinuousClock.now
    var keepsDate = false
}

struct ContextRequest {
    var snapshot: FieldSnapshot
    var exampleLimit: Int
    var includeScreen: Bool
    var clipboard: String?
    var sessionKey: String?
    var screenOptions: ScreenContextOptions

    init(
        snapshot: FieldSnapshot, exampleLimit: Int, includeScreen: Bool, allowOCR: Bool, clipboard: String?,
        sessionKey: String?
    ) {
        self.snapshot = snapshot
        self.exampleLimit = exampleLimit
        self.includeScreen = includeScreen
        self.clipboard = clipboard
        self.sessionKey = sessionKey
        screenOptions = ScreenContextOptions()
        screenOptions.allowOCR = allowOCR
        screenOptions.language = LanguageDetector.dominantLanguage(of: String(snapshot.textBefore.suffix(600)))
            ?? snapshot.language
    }

    nonisolated private static let log = Logger.gw("SessionContext")

    func load(memory: MemoryStore?, screen: ScreenContextProvider) async -> SessionContext {
        let snapshot = snapshot
        let options = screenOptions
        async let screenText: String? = includeScreen ? screen.text(for: snapshot, options: options) : nil
        let examples = await Self.examples(for: snapshot, limit: exampleLimit, excluding: sessionKey, memory: memory)
        return SessionContext(
            examples: examples,
            screenText: await screenText,
            clipboard: clipboard,
            windowTitle: snapshot.windowTitle
        )
    }

    func screenTextAfterOCR(screen: ScreenContextProvider) async -> String? {
        guard includeScreen, screenOptions.allowOCR else { return nil }
        return await screen.textAfterOCR(for: snapshot, options: screenOptions)
    }

    static func examples(for snapshot: FieldSnapshot, limit: Int, excluding sessionKey: String?, memory: MemoryStore?) async -> [String] {
        guard let memory, limit > 0 else { return [] }
        let query = String(snapshot.textBefore.suffix(600))
        let language = LanguageDetector.dominantLanguage(of: query)
        let bundleID = snapshot.app.bundleID
        return await Task.detached {
            do {
                return try memory.examples(query: query, bundleID: bundleID, language: language, limit: limit, excludingKey: sessionKey)
            } catch {
                log.error("Fetching examples failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }.value
    }
}
