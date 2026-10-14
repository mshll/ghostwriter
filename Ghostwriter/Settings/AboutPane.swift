import AppKit
import SwiftUI

struct AboutPane: View {
    private static let gemmaTerms = URL(string: "https://ai.google.dev/gemma/terms")
    private static let sourceCode = URL(string: "https://github.com/mshll/ghostwriter")
    private static let bugReport = URL(string: "https://github.com/mshll/ghostwriter/issues/new")

    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState
    @Environment(ModelLibrary.self) private var models
    @State private var copied: String?

    var body: some View {
        SettingsPaneView(pane: .about) {
            Section {
                SettingRow(AboutSetting.version) {
                    HStack(spacing: 10) {
                        Text(AppVersion.label)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        copyButton("Version") { "Ghostwriter \(AppVersion.label)" }
                    }
                }
                if let sourceCode = Self.sourceCode {
                    LinkRow(AboutSetting.sourceCode, url: sourceCode)
                }
            }

            Section {
                if let bugReport = Self.bugReport {
                    LinkRow(AboutSetting.reportBug, url: bugReport)
                }
                SettingRow(AboutSetting.diagnostics) {
                    copyButton("Diagnostics") {
                        Diagnostics.report(preferences: preferences, appState: appState, models: models)
                    }
                }
            } header: {
                Text("Feedback")
            }

            Section {
                Text("Built with llama.cpp, GRDB, KeyboardShortcuts and Sparkle. Gemma models are provided under the Gemma Terms of Use.")
                    .foregroundStyle(.secondary)
                    .settingsSearchTarget(AboutSetting.acknowledgments)
                if let gemmaTerms = Self.gemmaTerms {
                    LinkRow(AboutSetting.gemmaTerms, url: gemmaTerms)
                }
            } header: {
                Text("Acknowledgments")
            }
        }
        .animation(.easeOut(duration: 0.15), value: copied)
        .task(id: copied) {
            guard copied != nil else { return }
            do {
                try await Task.sleep(for: .seconds(1.4))
            } catch {
                return
            }
            copied = nil
        }
    }

    private func copyButton(_ row: String, text: @escaping () -> String) -> some View {
        Button(copied == row ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = row
        }
    }
}

enum AboutSetting: SettingKey {
    case version, sourceCode, reportBug, diagnostics, acknowledgments, gemmaTerms

    var text: SettingText {
        switch self {
        case .version: SettingText("Version", keywords: ["build", "copy"])
        case .sourceCode: SettingText("Source Code", keywords: ["github", "open source", "repository"])
        case .reportBug: SettingText("Report a Bug", keywords: ["issue", "github", "feedback", "problem"])
        case .diagnostics: SettingText("Diagnostics", subtitle: "Your Mac, macOS, the model and your settings, to paste into a bug report. Never anything you wrote.", keywords: ["copy", "system", "bug", "report"])
        case .acknowledgments: SettingText("Acknowledgments", keywords: ["acknowledgements", "licenses", "open source", "credits"])
        case .gemmaTerms: SettingText("Gemma Terms of Use", keywords: ["license"])
        }
    }
}
