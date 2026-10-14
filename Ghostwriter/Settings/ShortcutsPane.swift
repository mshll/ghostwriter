import Input
import KeyboardShortcuts
import SwiftUI

struct ShortcutsPane: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPaneView(pane: .shortcuts) {
            Section {
                AcceptKeyRow(
                    key: .acceptFull,
                    hotKey: $preferences.acceptFullKey,
                    otherKey: preferences.acceptWordKey
                )
                AcceptKeyRow(
                    key: .acceptWord,
                    hotKey: $preferences.acceptWordKey,
                    otherKey: preferences.acceptFullKey
                )
            } header: {
                Text("While a suggestion is showing")
            } footer: {
                Text("These keys only act while a suggestion is visible; otherwise they type as usual. Press \u{2325}Tab to type a real Tab.")
            }

            Section {
                ForEach(ShortcutsSetting.global, id: \.self) { key in
                    SettingRow(key) {
                        if let name = key.shortcutName {
                            KeyboardShortcuts.Recorder(for: name)
                        }
                    }
                }
            } header: {
                Text("Anywhere")
            }

            Section {
                SettingRow(ShortcutsSetting.restoreDefaults) {
                    Button("Restore Defaults", action: restoreDefaults)
                }
            }
        }
    }

    private func restoreDefaults() {
        KeyboardShortcuts.reset(KeyboardShortcuts.Name.global)
        preferences.restoreDefaultAcceptKeys()
    }
}

private struct AcceptKeyRow: View {
    let key: ShortcutsSetting
    @Binding var hotKey: HotKey
    let otherKey: HotKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(key) {
                HotKeyRecorder(hotKey: $hotKey)
            }
            if let warning = HotKey.acceptKeyWarning(for: hotKey, otherKey: otherKey) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum ShortcutsSetting: SettingKey {
    case acceptFull, acceptWord
    case pause, pauseInApp, suggestNow, longDraft, selectionActions, proofread
    case restoreDefaults

    static let global: [Self] = [.pause, .pauseInApp, .suggestNow, .longDraft, .selectionActions, .proofread]

    var shortcutName: KeyboardShortcuts.Name? {
        switch self {
        case .pause: .toggleCompletions
        case .pauseInApp: .toggleCompletionsInApp
        case .suggestNow: .forceComplete
        case .longDraft: .longDraft
        case .selectionActions: .selectionActions
        case .proofread: .proofread
        case .acceptFull, .acceptWord, .restoreDefaults: nil
        }
    }

    var text: SettingText {
        let global = ["hotkey", "keyboard", "global"]
        return switch self {
        case .acceptFull: SettingText("Accept the whole suggestion", keywords: ["tab", "accept", "key"])
        case .acceptWord: SettingText("Accept the next word", keywords: ["tab", "accept", "key"])
        case .pause: SettingText("Turn suggestions off or on", subtitle: "The same switch as Show suggestions.", keywords: global + ["pause", "resume"])
        case .pauseInApp: SettingText("Pause or resume in the current app", subtitle: "Pauses for 15 minutes. Press it again to turn suggestions back on.", keywords: global)
        case .suggestNow: SettingText("Suggest now", subtitle: "For fields where suggestions don\u{2019}t start on their own.", keywords: global)
        case .longDraft: SettingText("Write a longer draft", subtitle: "Continues with a sentence or a paragraph.", keywords: global)
        case .selectionActions: SettingText("Actions for selected text", keywords: global)
        case .proofread: SettingText("Proofread", subtitle: "Fixes the selection, or the paragraph before the cursor. Press it again to undo.", keywords: global + ["typo", "spelling", "grammar"])
        case .restoreDefaults: SettingText("Restore defaults", subtitle: "Puts every key and shortcut on this page back.", keywords: ["reset"])
        }
    }
}
