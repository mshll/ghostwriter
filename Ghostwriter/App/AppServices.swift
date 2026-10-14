import Actions
import Foundation
import GWCore
import Inference
import Memory
import Observation
import Sparkle
import os

@Observable
final class AppServices {
    private static let log = Logger.gw("AppServices")

    let memory: MemoryStore?
    let engine = CompletionEngine()
    let downloader: ModelDownloader
    let assistant = WritingAssistant()
    let models: ModelLibrary
    let appRules: AppRuleLibrary
    let snippets: SnippetLibrary
    let updaterController: SPUStandardUpdaterController
    private let updateReminder: UpdateReminder

    init(preferences: Preferences, appState: AppState) {
        let memory = Self.openMemory(appState: appState)
        let downloader = ModelDownloader()
        self.memory = memory
        self.downloader = downloader
        models = ModelLibrary(preferences: preferences, appState: appState, downloader: downloader)
        appRules = AppRuleLibrary(store: memory)
        snippets = SnippetLibrary(store: memory)
        updateReminder = UpdateReminder(appState: appState)
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: updateReminder)
        if !WritingAssistant.isAvailable {
            appState.foundationModelsUnavailableReason = WritingAssistant.unavailableReason ?? "Apple Intelligence is not available on this Mac."
        }
    }

    func refreshWordsToday(into appState: AppState) {
        guard let memory else { return }
        do {
            appState.wordsToday = try memory.wordsAcceptedToday()
        } catch {
            Self.log.error("Reading today's words failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func openMemory(appState: AppState) -> MemoryStore? {
        do {
            try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            return try MemoryStore(url: AppPaths.database)
        } catch {
            log.error("Opening the database failed: \(error.localizedDescription, privacy: .public)")
            appState.databaseError = error.localizedDescription
        }
        do {
            return try MemoryStore.inMemory()
        } catch {
            log.error("Opening an in-memory database failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
