import SwiftUI

struct PersonalizationPane: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPaneView(pane: .personalization) {
            Section {
                SettingRow(PersonalizationSetting.learn, isOn: $preferences.recordWriting)
                StrengthSlider(strength: $preferences.personalizationStrengthValue)
                    .disabled(!preferences.recordWriting)
            } header: {
                Text("Your writing")
            } footer: {
                Text("Recorded writing can be erased in Privacy & Data.")
            }

            Section {
                SettingRow(PersonalizationSetting.name) {
                    TextField("Your name", text: $preferences.userName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                InstructionsEditor(text: $preferences.customInstructions)
                    .settingsSearchTarget(PersonalizationSetting.instructions)
            } header: {
                Text("About you")
            } footer: {
                Text("Instructions apply to every app. Add app-specific ones in Apps.")
            }

            if services.cotypist.isAvailable {
                Section {
                    CotypistImportRow(importer: services.cotypist)
                }
            }
        }
    }
}

private struct CotypistImportRow: View {
    let importer: CotypistImporter

    var body: some View {
        SettingRow(PersonalizationSetting.cotypist, subtitle: status) {
            if importer.phase == .importing {
                ProgressView().controlSize(.small)
            } else {
                Button("Import", action: importer.run)
            }
        }
    }

    private var status: String? {
        switch importer.phase {
        case .idle, .importing: nil
        case .finished(let summary): summary
        case .failed(let message): message
        }
    }
}

extension Preferences {
    fileprivate var personalizationStrengthValue: Double {
        get { Double(personalizationStrength) }
        set { personalizationStrength = Int(newValue.rounded()) }
    }
}

private struct StrengthSlider: View {
    private static let labels = ["Off", "Subtle", "Light", "Balanced", "Strong", "Max"]

    @Binding var strength: Double

    var body: some View {
        SettingRow(PersonalizationSetting.strength) {
            VStack(alignment: .leading, spacing: 2) {
                Slider(value: $strength, in: 0...5, step: 1) {
                    Text("Favor your own words")
                }
                HStack {
                    Text(Self.labels.first ?? "")
                    Spacer()
                    Text(Self.labels[Int(strength).clamped(to: 0...(Self.labels.count - 1))])
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(Self.labels.last ?? "")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(width: 220)
        }
    }
}

private struct InstructionsEditor: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instructions")
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Describe yourself and how you write. For example: I lead a design team and mostly write to clients and teammates. I write in English and Arabic. Keep a warm, direct tone with short sentences.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }
}

enum PersonalizationSetting: SettingKey {
    case learn, strength, name, instructions, cotypist

    var text: SettingText {
        switch self {
        case .learn: SettingText("Learn from what you write", subtitle: "Ghostwriter stores the text of fields where it suggests, on this Mac only, and uses it to match your words and style. It never records password fields. Turn recording off per app in Apps or from the menu bar.", keywords: ["record", "history", "style"])
        case .strength: SettingText("Favor your own words", subtitle: "Higher values follow your habits more closely and can occasionally pick a less fitting word.", keywords: ["strength", "personalization"])
        case .name: SettingText("Your name", subtitle: "Used when a suggestion needs your name.", keywords: ["sign-off", "signature"])
        case .instructions: SettingText("Instructions", keywords: ["custom", "prompt", "tone", "about you"])
        case .cotypist: SettingText("Import from Cotypist", subtitle: "Brings over your recorded writing, instructions and app settings. macOS asks you to allow access.", keywords: ["import", "migrate", "transfer", "history"])
        }
    }
}
