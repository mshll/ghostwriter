import GWCore
import SwiftUI

struct SnippetsPane: View {
    @Environment(SnippetLibrary.self) private var library
    @State private var path: [Snippet] = []

    var body: some View {
        NavigationStack(path: $path) {
            SettingsPaneView(pane: .snippets) {
                Section {
                    if library.snippets.isEmpty {
                        Text("No snippets yet. Type a short trigger like ;addr anywhere and Ghostwriter replaces it with the full text.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.snippets) { snippet in
                        NavigationLink(value: snippet) {
                            SnippetRow(snippet: snippet)
                        }
                        .contextMenu {
                            Button(snippet.isEnabled ? "Turn Off" : "Turn On") {
                                var toggled = snippet
                                toggled.isEnabled.toggle()
                                library.save(toggled)
                            }
                            Button("Delete Snippet", role: .destructive) { library.delete(id: snippet.id) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Snippets")
                            .settingsSearchTarget(SnippetsSetting.snippets)
                        Spacer()
                        Button("Add Snippet") { path = [Snippet(trigger: "", body: "")] }
                    }
                } footer: {
                    if let error = library.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationDestination(for: Snippet.self) { snippet in
                SnippetEditor(snippet: snippet) {
                    path.removeAll()
                    library.delete(id: snippet.id)
                }
            }
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snippet.trigger)
            Text(snippet.body.prefix { !$0.isNewline })
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .opacity(snippet.isEnabled ? 1 : 0.5)
    }
}

private struct SnippetEditor: View {
    @Environment(SnippetLibrary.self) private var library
    @State private var draft: Snippet
    private let delete: () -> Void

    init(snippet: Snippet, delete: @escaping () -> Void) {
        _draft = State(initialValue: snippet)
        self.delete = delete
    }

    private var isSaved: Bool { library.snippets.contains { $0.id == draft.id } }

    private var unsavedError: String? {
        guard let error = library.validationError(for: draft) else { return nil }
        let stored = library.snippets.first { $0.id == draft.id }
        let changed = stored.map { $0 != draft } ?? !(draft.trigger.isEmpty && draft.body.isEmpty)
        return changed ? error : nil
    }

    var body: some View {
        SettingsPage(title: draft.trigger.isEmpty ? "New Snippet" : draft.trigger, summary: "Type the trigger anywhere to insert the text.") {
            SettingsPaneIcon(pane: .snippets, size: SettingsPaneIcon.compactSize)
        } content: {
            Section {
                SettingRow(title: "Trigger", subtitle: "A short word with no spaces, for example ;addr.") {
                    TextField("Trigger", text: $draft.trigger, prompt: Text(";addr"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                SettingRow(title: "On") {
                    Toggle("On", isOn: $draft.isEnabled)
                }
            } footer: {
                if let unsavedError {
                    Label("Not saved: \(unsavedError)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                TextEditor(text: $draft.body)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Expands to")
            } footer: {
                Text("Placeholders: {date}, {time}, {clipboard}, {cursor} (where the cursor lands), {ai: write a friendly sign-off} (filled by Apple Intelligence).")
            }

            Section {
                Button("Delete Snippet", role: .destructive, action: delete)
                    .frame(maxWidth: .infinity)
            }
        }
        .settingsBackButton(discardWarning: unsavedError.map { "\($0) \(isSaved ? "Going back keeps the last saved version." : "Going back drops this snippet.")" })
        .onChange(of: draft) { library.save(draft) }
    }
}

enum SnippetsSetting: SettingKey {
    case snippets

    var text: SettingText {
        switch self {
        case .snippets: SettingText("Snippets", keywords: ["trigger", "expand", "text expansion", "placeholder"])
        }
    }
}
