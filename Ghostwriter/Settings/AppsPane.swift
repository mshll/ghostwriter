import AppKit
import Capture
import GWCore
import SwiftUI
import UniformTypeIdentifiers

struct AppsPane: View {
    @Environment(AppRuleLibrary.self) private var library
    @Environment(AppState.self) private var appState
    @Environment(SettingsNavigation.self) private var navigation
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            SettingsPaneView(pane: .apps) {
                if !pausedApps.isEmpty {
                    Section {
                        ForEach(pausedApps, id: \.self) { bundleID in
                            PausedAppRow(bundleID: bundleID)
                        }
                    } header: {
                        Text("Paused from the menu bar")
                    }
                }

                Section {
                    if library.rules.isEmpty {
                        Text("No apps yet. Add one to change how Ghostwriter behaves in it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.rules) { rule in
                        NavigationLink(value: rule.bundleID) {
                            AppRow(rule: rule)
                        }
                        .contextMenu {
                            Button("Remove App", role: .destructive) { remove(rule.bundleID) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Apps")
                            .settingsSearchTarget(AppsSetting.apps)
                        Spacer()
                        AddAppMenu(add: add)
                    }
                }
            }
            .navigationDestination(for: String.self) { bundleID in
                if let rule = library.rule(for: bundleID) {
                    AppRuleEditor(rule: rule) { remove(bundleID) }
                }
            }
        }
        .onChange(of: navigation.app, initial: true) { _, bundleID in
            guard let bundleID else { return }
            navigation.app = nil
            add(bundleID)
        }
    }

    private var pausedApps: [String] {
        appState.appPauses
            .filter { $0.value.isActive }
            .keys
            .sorted { AppInfo.name(for: $0).localizedStandardCompare(AppInfo.name(for: $1)) == .orderedAscending }
    }

    private func add(_ bundleID: String) {
        if library.rule(for: bundleID) == nil {
            library.save(AppRule(bundleID: bundleID))
        }
        path = [bundleID]
    }

    private func remove(_ bundleID: String) {
        path.removeAll()
        library.delete(bundleID: bundleID)
    }
}

private struct PausedAppRow: View {
    @Environment(AppState.self) private var appState
    let bundleID: String

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppInfo.icon(for: bundleID))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.name(for: bundleID))
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    if let pause = appState.appPauses[bundleID] {
                        Text(pause.summary(scope: "here"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Resume") { appState.resume(bundleID: bundleID) }
        }
    }
}

private struct AppRow: View {
    let rule: AppRule

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppInfo.icon(for: rule.bundleID))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppInfo.name(for: rule.bundleID))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        if rule.completionsEnabled == false { return "Suggestions off" }
        if rule != AppRule(bundleID: rule.bundleID) { return "Changed settings" }
        return BuiltInAppRules.rule(for: rule.bundleID) != nil ? "Built-in adjustments" : "No changes yet"
    }
}

private struct AddAppMenu: View {
    let add: (String) -> Void

    var body: some View {
        Menu {
            Section("Running apps") {
                ForEach(runningApps, id: \.bundleID) { app in
                    Button(app.name) { add(app.bundleID) }
                }
            }
            Divider()
            Button("Choose an App\u{2026}", action: chooseApp)
        } label: {
            Text("Add App")
        }
        .fixedSize()
    }

    private var runningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        add(bundleID)
    }
}

private struct AppRuleEditor: View {
    @Environment(AppRuleLibrary.self) private var library
    @Environment(Preferences.self) private var preferences
    @State private var draft: AppRule
    private let builtIn: AppRule?
    private let remove: () -> Void

    init(rule: AppRule, remove: @escaping () -> Void) {
        _draft = State(initialValue: rule)
        builtIn = BuiltInAppRules.rule(for: rule.bundleID)
        self.remove = remove
    }

    var body: some View {
        SettingsPage(title: AppInfo.name(for: draft.bundleID), summary: draft.bundleID) {
            AppIconTile(image: AppInfo.icon(for: draft.bundleID), size: SettingsPaneIcon.compactSize)
        } content: {
            Section {
                RuleChoice("Show suggestions", value: $draft.completionsEnabled,
                           fallback: builtIn?.completionsEnabled ?? preferences.completionsEnabled)
                RuleChoice("Complete inside existing text", value: $draft.midLineEnabled,
                           fallback: builtIn?.midLineEnabled ?? preferences.midLineEnabled)
                RuleChoice("Accept with Tab", value: $draft.tabAcceptEnabled,
                           fallback: builtIn?.tabAcceptEnabled ?? true)
                RuleChoice("Fix typos", value: $draft.typoFixesEnabled,
                           fallback: builtIn?.typoFixesEnabled ?? preferences.typoFixesEnabled)
                RuleChoice("Complete in code editors", value: $draft.codeEditorCompletions,
                           fallback: builtIn?.codeEditorCompletions ?? false)
            } header: {
                Text("Suggestions")
            } footer: {
                if builtIn != nil {
                    Text("Ghostwriter has built-in adjustments for this app. \u{201C}Default\u{201D} uses them.")
                }
            }

            Section("Context and privacy") {
                RuleChoice("Use text from the window", value: $draft.screenContextEnabled,
                           fallback: builtIn?.screenContextEnabled ?? preferences.screenContextEnabled)
                RuleChoice("Learn from what you write here", value: $draft.recordWriting,
                           fallback: builtIn?.recordWriting ?? preferences.recordWriting)
            }

            Section {
                SettingRow(title: "Insert text by") {
                    Picker("Insert text by", selection: $draft.insertionChoice) {
                        Text("Default (\((builtIn?.insertionMode).insertionChoice.title))").tag(InsertionChoice.automatic)
                        Text(InsertionChoice.keystrokes.title).tag(InsertionChoice.keystrokes)
                        Text(InsertionChoice.paste.title).tag(InsertionChoice.paste)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                RuleChoice("Improve compatibility", value: $draft.needsEnhancedUserInterface,
                           fallback: builtIn?.needsEnhancedUserInterface ?? false)
            } header: {
                Text("Compatibility")
            } footer: {
                Text("Try pasting if accepted text arrives garbled. Improve compatibility asks web-based apps to expose their text fields; turn it on if suggestions never appear.")
            }

            Section("Instructions for this app") {
                TextEditor(text: $draft.instructionsText)
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if draft.instructionsText.isEmpty {
                            Text("For example: Messages here are casual, in Spanish.")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }

            Section {
                Button("Remove App", role: .destructive, action: remove)
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("Removing an app returns it to the settings every app uses.")
            }
        }
        .settingsBackButton()
        .onChange(of: draft) { library.save(draft) }
        // A rule with no changes acts like no rule, so it would only clutter the list.
        .onDisappear {
            if library.rule(for: draft.bundleID) == AppRule(bundleID: draft.bundleID) { library.delete(bundleID: draft.bundleID) }
        }
        .onChange(of: library.rule(for: draft.bundleID)) { _, stored in
            // The menu bar can change this rule while the editor is open.
            if let stored, stored != draft { draft = stored }
        }
    }
}

private struct RuleChoice: View {
    let title: String
    @Binding var value: Bool?
    let fallback: Bool

    init(_ title: String, value: Binding<Bool?>, fallback: Bool) {
        self.title = title
        _value = value
        self.fallback = fallback
    }

    var body: some View {
        SettingRow(title: title) {
            Picker(title, selection: $value) {
                Text("Default (\(fallback ? "On" : "Off"))").tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

enum InsertionChoice: Hashable {
    case automatic, keystrokes, paste

    var title: String {
        switch self {
        case .automatic: "Default"
        case .keystrokes: "Typing"
        case .paste: "Pasting"
        }
    }
}

extension Optional where Wrapped == InsertionMode {
    fileprivate var insertionChoice: InsertionChoice {
        switch self {
        case .paste: .paste
        case .keystrokes, nil: .keystrokes
        }
    }
}

extension AppRule {
    fileprivate var insertionChoice: InsertionChoice {
        get {
            switch insertionMode {
            case nil: .automatic
            case .keystrokes: .keystrokes
            case .paste: .paste
            }
        }
        set {
            switch newValue {
            case .automatic: insertionMode = nil
            case .keystrokes: insertionMode = .standard
            case .paste: insertionMode = .paste
            }
        }
    }

    fileprivate var instructionsText: String {
        get { customInstructions ?? "" }
        set { customInstructions = newValue.isEmpty ? nil : newValue }
    }
}

enum AppsSetting: SettingKey {
    case apps

    var text: SettingText {
        switch self {
        case .apps: SettingText("Apps", keywords: ["per-app", "exclude", "disable", "rules", "paste", "compatibility", "code editor", "paused", "resume"])
        }
    }
}
