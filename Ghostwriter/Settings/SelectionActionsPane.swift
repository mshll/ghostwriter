import Actions
import KeyboardShortcuts
import SwiftUI

struct SelectionActionsPane: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPaneView(pane: .selectionActions) {
            Section {
                AvailabilityRow()
                SettingRow(SelectionActionsSetting.offer, isOn: $preferences.selectionActionsEnabled)
                SettingRow(SelectionActionsSetting.shortcut) {
                    KeyboardShortcuts.Recorder(for: .selectionActions)
                }
                .disabled(!preferences.selectionActionsEnabled)
                SettingRow(SelectionActionsSetting.toolbarOnSelect, isOn: $preferences.showsSelectionActionsOnSelect)
                .disabled(!preferences.selectionActionsEnabled)
            }

            Section {
                SettingRow(SelectionActionsSetting.proofread, isOn: $preferences.proofreadEnabled)
                SettingRow(SelectionActionsSetting.proofreadShortcut) {
                    KeyboardShortcuts.Recorder(for: .proofread)
                }
                .disabled(!preferences.proofreadEnabled)
            } header: {
                Text("Proofread")
            }

            Section {
                ForEach(WritingAction.allCases) { action in
                    Toggle(isOn: $preferences[isEnabled: action]) {
                        Label(action.title, systemImage: action.symbol)
                    }
                    .settingsSearchTarget(SelectionActionsSetting.action(action))
                }
                SettingRow(SelectionActionsSetting.translateInto) {
                    Picker("Translate into", selection: $preferences.translateTargetLanguage) {
                        ForEach(WritingAction.translationLanguages, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            } header: {
                Text("Actions in the panel")
            } footer: {
                Text("Number keys pick an action, Return replaces your selection, \u{2318}C copies the result. A single word or short phrase also offers synonyms.")
            }
            .disabled(!preferences.selectionActionsEnabled)
        }
    }
}

extension Preferences {
    subscript(isEnabled action: WritingAction) -> Bool {
        get { enabledActions.contains(action) }
        set {
            if newValue {
                enabledActions.insert(action)
            } else {
                enabledActions.remove(action)
            }
        }
    }
}

private struct AvailabilityRow: View {
    var body: some View {
        if WritingAssistant.isAvailable {
            Label("Apple Intelligence is ready", systemImage: "apple.intelligence")
                .foregroundStyle(.secondary)
        } else {
            Label(
                WritingAssistant.unavailableReason ?? "Apple Intelligence is unavailable, so selection actions are hidden.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        }
    }
}

enum SelectionActionsSetting: SettingKey, Hashable {
    case offer, shortcut, toolbarOnSelect
    case proofread, proofreadShortcut
    case action(WritingAction)
    case translateInto

    nonisolated static var allCases: [Self] {
        [.offer, .shortcut, .toolbarOnSelect, .proofread, .proofreadShortcut] + WritingAction.allCases.map(Self.action) + [.translateInto]
    }

    var text: SettingText {
        switch self {
        case .offer: SettingText("Offer actions for selected text", subtitle: "Select text in any app and press the shortcut to rephrase, fix, shorten or translate it with Apple Intelligence, on this Mac.", keywords: ["apple intelligence", "rewrite", "rephrase"])
        case .shortcut: SettingText("Shortcut", keywords: ["hotkey"])
        case .toolbarOnSelect: SettingText("Show the toolbar when you select text", subtitle: "The toolbar appears once you stop selecting. Typing, clicking elsewhere or Esc hides it.", keywords: ["popup", "selection"])
        case .proofread: SettingText("Proofread with a shortcut", subtitle: "Fixes spelling, grammar and punctuation in the selection, or in the paragraph before the cursor, without changing your wording. Press the shortcut again to undo.", keywords: ["typo", "spelling", "grammar", "autocorrect"])
        case .proofreadShortcut: SettingText("Proofread shortcut", keywords: ["hotkey"])
        case .action(let action): SettingText(action.title)
        case .translateInto: SettingText("Translate into", keywords: ["language", "translation"])
        }
    }
}
