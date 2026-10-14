import GWCore
import SwiftUI

struct SuggestionsPane: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState
    @State private var practiceText = ""

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPaneView(pane: .suggestions) {
            Section {
                SettingRow(SuggestionsSetting.showSuggestions, isOn: $preferences.completionsEnabled)
                SettingRow(SuggestionsSetting.length) {
                    Picker("Suggestion length", selection: $preferences.completionLength) {
                        ForEach(CompletionLength.allCases) { length in
                            Text("\(length.title) (\(length.wordRange))").tag(length)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                SettingRow(SuggestionsSetting.insideText, isOn: $preferences.midLineEnabled)
                SettingRow(SuggestionsSetting.drafts, isOn: $preferences.draftEnabled)
            }

            Section {
                SettingRow(SuggestionsSetting.punctuation, isOn: $preferences.includeTrailingPunctuation)
                SettingRow(SuggestionsSetting.space, isOn: $preferences.includeTrailingSpace)
                SettingRow(SuggestionsSetting.escape) {
                    Picker("When you press Escape", selection: $preferences.escapeBehavior) {
                        ForEach(EscapeBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            } header: {
                Text("Accepting")
            } footer: {
                Text("The keys that accept a suggestion are set in Shortcuts.")
            }

            Section {
                SettingRow(SuggestionsSetting.typoFixes, isOn: $preferences.typoFixesEnabled)
                SettingRow(SuggestionsSetting.autoFix, isOn: $preferences.autoFixTypos)
                    .disabled(!preferences.typoFixesEnabled)
                SettingRow(SuggestionsSetting.sentenceCheck, isOn: $preferences.sentenceTypoCheck)
                    .disabled(!preferences.typoFixesEnabled)
                SettingRow(SuggestionsSetting.holdBack, isOn: $preferences.suppressOnTypo)
                SettingRow(SuggestionsSetting.ignoredWords) {
                    IgnoredWordsButton(words: $preferences.ignoredTypoWords)
                }
                SettingRow(SuggestionsSetting.emoji, isOn: $preferences.emojiEnabled)
            } header: {
                Text("Typos and emoji")
            } footer: {
                Text("Typos are checked on this Mac with the system dictionary and the suggestion model. Words you often write are never flagged.")
            }

            Section {
                SettingRow(SuggestionsSetting.opacity) {
                    Slider(value: $preferences.overlayOpacity, in: 0.2...0.8) {
                        Text("Suggestion opacity")
                    }
                    .frame(width: 200)
                }
                SuggestionPreview(opacity: preferences.overlayOpacity)
            } header: {
                Text("Appearance")
            }

            Section {
                PracticeField(text: $practiceText, placeholder: "Type the start of a sentence and pause\u{2026}")
                    .frame(height: 90)
                    .settingsSearchTarget(SuggestionsSetting.tryIt)
                if let blocker {
                    Label(blocker, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Try it here")
            } footer: {
                Text("Changes above apply here at once. What you type here is not saved or counted in Statistics.")
            }
        }
    }

    private var blocker: String? {
        if !appState.accessibilityGranted { return "Suggestions appear here once Accessibility access is allowed in General." }
        switch appState.modelStatus {
        case .ready: return nil
        case .downloading: return "Suggestions start when the model finishes downloading."
        case .loading: return "The model is loading."
        case .notInstalled: return "Download a model in Model to get suggestions."
        case .failed: return "The model failed to load. See Model."
        }
    }
}

private struct SuggestionPreview: View {
    let opacity: Double

    var body: some View {
        Text("Thanks for the update, I\u{2019}ll \(Text("send the revised draft tomorrow.").foregroundStyle(.primary.opacity(opacity)))")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .accessibilityLabel("Preview of a suggestion at the chosen opacity")
    }
}

extension CompletionLength {
    var wordRange: String {
        switch self {
        case .short: "1\u{2013}2 words"
        case .medium: "2\u{2013}4 words"
        case .long: "4\u{2013}7 words"
        case .veryLong: "7\u{2013}10 words"
        case .ultraLong: "10\u{2013}15 words"
        }
    }
}

enum SuggestionsSetting: SettingKey {
    case showSuggestions, length, insideText, drafts, punctuation, space, escape
    case typoFixes, autoFix, sentenceCheck, holdBack, ignoredWords, emoji, opacity, tryIt

    var text: SettingText {
        switch self {
        case .showSuggestions: SettingText("Show suggestions", subtitle: "Turn this off to stop suggestions everywhere. Apps can override it in Apps.", keywords: ["enable", "disable", "completions", "autocomplete"])
        case .length: SettingText("Suggestion length", subtitle: "Shorter suggestions are right more often. Medium suits most writing.", keywords: ["words", "short", "long", "completions"])
        case .insideText: SettingText("Complete inside existing text", subtitle: "Also suggest when there is text after the cursor on the same line.", keywords: ["mid-line", "middle", "cursor"])
        case .drafts: SettingText("Longer drafts on demand", subtitle: "A shortcut writes a sentence or a paragraph from where you are. Set it in Shortcuts.", keywords: ["paragraph", "sentence", "draft"])
        case .punctuation: SettingText("Take punctuation with the next word", subtitle: "Accepting one word also takes a comma or period attached to it.", keywords: ["accept", "comma", "period"])
        case .space: SettingText("Take the space after the next word", keywords: ["accept"])
        case .escape: SettingText("When you press Escape", keywords: ["esc", "dismiss", "pause", "hide"])
        case .typoFixes: SettingText("Suggest fixes for typos", subtitle: "Strikes through a misspelled word and shows the fix. Tab applies it; Esc stops flagging that word.", keywords: ["spelling", "correction", "autocorrect"])
        case .autoFix: SettingText("Fix obvious typos as you type", subtitle: "Only when the dictionary and the model agree. Press Delete right after to undo and keep your word.", keywords: ["spelling", "autocorrect", "automatic"])
        case .sentenceCheck: SettingText("Check each sentence when it ends", subtitle: "Offers fixes for typos you typed past.", keywords: ["spelling", "sentence", "period"])
        case .ignoredWords: SettingText("Words not flagged", subtitle: "Words you kept with Esc or by undoing a fix.", keywords: ["ignore", "dictionary", "spelling", "learn"])
        case .holdBack: SettingText("Hold back suggestions after a likely typo", keywords: ["spelling"])
        case .emoji: SettingText("Suggest emoji", subtitle: "Type a colon and a word, for example :smile, to pick an emoji.", keywords: ["colon", "smile"])
        case .opacity: SettingText("Suggestion opacity", keywords: ["transparency", "ghost", "grey", "gray", "appearance"])
        case .tryIt: SettingText("Try it here")
        }
    }
}

private struct IgnoredWordsButton: View {
    @Binding var words: [String]
    @State private var isShowing = false

    var body: some View {
        Button(words.isEmpty ? "None" : "\(words.count) \(words.count == 1 ? "word" : "words")\u{2026}") {
            isShowing = true
        }
        .disabled(words.isEmpty)
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            List {
                ForEach(words, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle.fill") {
                            words.removeAll { $0 == word }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 240, height: min(CGFloat(words.count) * 28 + 20, 320))
        }
    }
}
