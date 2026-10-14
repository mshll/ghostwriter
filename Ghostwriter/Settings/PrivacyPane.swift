import AppKit
import GWCore
import Memory
import SwiftUI
import os

struct PrivacyPane: View {
    private static let log = Logger.gw("Privacy")

    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState
    @Environment(AppServices.self) private var services
    @State private var count: Int?
    @State private var isConfirmingErase = false
    @State private var isConfirmingReset = false
    @State private var errorMessage: String?

    var body: some View {
        SettingsPaneView(pane: .privacy) {
            Section {
                if let databaseError = appState.databaseError {
                    Label("The database couldn\u{2019}t be opened, so nothing is saved this session: \(databaseError)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                SettingRow(PrivacySetting.recordedWriting, subtitle: recordedSubtitle) {
                    Button("Erase All\u{2026}", role: .destructive) { isConfirmingErase = true }
                        .disabled(services.memory == nil || count == 0)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Ghostwriter learns your style from this text. Turn recording off in Personalization, or per app in Apps.")
            }

            Section {
                SettingRow(PrivacySetting.dataFolder) {
                    Button("Show in Finder") { reveal(AppPaths.support) }
                }
                SettingRow(PrivacySetting.modelFiles) {
                    Button("Show in Finder", action: services.models.revealModelsFolder)
                }
            } footer: {
                Text("Ghostwriter connects to the internet only to download models and check for updates.")
            }

            Section {
                SettingRow(PrivacySetting.reset) {
                    Button("Reset\u{2026}", role: .destructive) { isConfirmingReset = true }
                }
            }
        }
        .task { load() }
        .confirmationDialog("Erase all recorded writing?", isPresented: $isConfirmingErase) {
            Button("Erase", role: .destructive, action: erase)
        } message: {
            Text("This deletes \(count ?? 0) recorded texts from this Mac. Suggestions stop adapting to your style until you write more. This can\u{2019}t be undone.")
        }
        .confirmationDialog("Reset all settings?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive, action: preferences.resetAll)
        } message: {
            Text("Every setting and shortcut returns to its default.")
        }
    }

    private var recordedSubtitle: String {
        switch count {
        case nil: "Nothing is recorded this session."
        case 0: "Nothing has been recorded yet."
        case 1: "1 text is stored on this Mac."
        case let count?: "\(count.formatted()) texts are stored on this Mac."
        }
    }

    private func load() {
        guard let memory = services.memory else { return }
        do {
            count = try memory.writingCount(bundleID: nil)
        } catch {
            Self.log.error("Counting writing failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func erase() {
        guard let memory = services.memory else { return }
        do {
            try memory.eraseWriting(bundleID: nil)
            errorMessage = nil
        } catch {
            Self.log.error("Erasing writing failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
        load()
    }

    private func reveal(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Self.log.error("Creating \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

enum PrivacySetting: SettingKey {
    case recordedWriting, dataFolder, modelFiles, reset

    var text: SettingText {
        switch self {
        case .recordedWriting: SettingText("Recorded writing", keywords: ["erase", "delete", "history", "texts"])
        case .dataFolder: SettingText("Writing, snippets and statistics", subtitle: "One database file on this Mac.", keywords: ["database", "folder", "finder", "files"])
        case .modelFiles: SettingText("Model files", keywords: ["folder", "finder", "gguf"])
        case .reset: SettingText("Reset all settings", subtitle: "Restores every setting and shortcut. Your writing, snippets, app rules and models stay.", keywords: ["defaults", "restore"])
        }
    }
}
