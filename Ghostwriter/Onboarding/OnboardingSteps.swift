import Inference
import KeyboardShortcuts
import Memory
import ScreenContext
import ServiceManagement
import SwiftUI

private struct Lede: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 17))
            .foregroundStyle(OnboardingStyle.inkSoft)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ContinueButton: View {
    let model: OnboardingModel

    var body: some View {
        Button("Continue") { model.completeHeadline(thenAdvance: true) }
            .buttonStyle(OnboardingButtonStyle())
    }
}

private struct Allowed: View {
    var body: some View {
        Label("Allowed", systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.green)
    }
}

struct AccessStep: View {
    let model: OnboardingModel
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 26) {
            Lede(text: "Ghostwriter reads the field you type in and types the words you take, through Accessibility. Your writing stays on this Mac.")
            if appState.accessibilityGranted {
                Label("Access allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.green)
            } else if model.guidedTopics.contains(.accessibility) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Turn on Ghostwriter in the list. This continues by itself.")
                    }
                    Text("Already on and nothing happens? Remove Ghostwriter with \u{2212} and drag it in again from the bar.")
                        .foregroundStyle(OnboardingStyle.muted.opacity(0.8))
                    HStack(spacing: 18) {
                        Button("Open System Settings") { model.guide(.accessibility) }
                        Button("Later", action: model.advance)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OnboardingStyle.ink)
                    .padding(.top, 6)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OnboardingStyle.muted)
            } else {
                Button("Open System Settings") { model.guide(.accessibility) }
                    .buttonStyle(OnboardingButtonStyle())
                Button("Later", action: model.advance)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnboardingStyle.muted)
            }
        }
    }
}

struct ModelStep: View {
    @Bindable var model: OnboardingModel
    @Environment(ModelLibrary.self) private var library
    @State private var showsOthers = false

    private var chosen: ModelSpec? { library.models.first { $0.id == model.chosenModelID } }

    var body: some View {
        VStack(spacing: 26) {
            OnboardingPanel {
                ForEach(listed) { spec in
                    if spec.id != listed.first?.id { OnboardingDivider() }
                    ModelRow(spec: spec, isChosen: spec.id == model.chosenModelID) { model.chosenModelID = spec.id }
                }
                if listed.count < library.models.count || showsOthers {
                    OnboardingDivider()
                    Button(showsOthers ? "Fewer models" : "Other models") {
                        withAnimation(.easeOut(duration: 0.25)) { showsOthers.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnboardingStyle.muted)
                    .padding(.vertical, 12)
                }
            }
            if let chosen {
                DownloadControl(model: model, spec: chosen)
            }
            Text("Downloaded once from Hugging Face, then it works offline.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingStyle.muted)
        }
        .onAppear(perform: library.refresh)
    }

    private var listed: [ModelSpec] {
        guard !showsOthers else { return library.models }
        return library.models.filter { $0.id == library.recommended?.id || $0.id == model.chosenModelID || library.activeModel?.id == $0.id }
    }
}

private struct ModelRow: View {
    let spec: ModelSpec
    let isChosen: Bool
    let choose: () -> Void
    @Environment(ModelLibrary.self) private var library

    var body: some View {
        Button(action: choose) {
            OnboardingRow(title: spec.displayName, detail: detail) {
                HStack(spacing: 12) {
                    Text(spec.sizeBytes.formatted(.byteCount(style: .file)))
                        .font(.system(size: 13))
                        .foregroundStyle(OnboardingStyle.muted)
                        .monospacedDigit()
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isChosen ? OnboardingStyle.accent : OnboardingStyle.muted.opacity(0.6))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        var parts: [String] = []
        if library.isRecommended(spec) {
            let hardware = library.hardware
            parts.append("Picked for this Mac, \(hardware.chip.replacingOccurrences(of: "Apple ", with: "")) with \(hardware.memoryGB) GB.")
        }
        if !spec.summary.isEmpty { parts.append(spec.summary) }
        if library.isInstalled(spec) { parts.append("Downloaded.") }
        return parts.joined(separator: " ")
    }
}

private struct DownloadControl: View {
    let model: OnboardingModel
    let spec: ModelSpec
    @Environment(ModelLibrary.self) private var library

    var body: some View {
        VStack(spacing: 12) {
            if let progress = library.downloadProgress[spec.id] {
                HStack(spacing: 14) {
                    ProgressView(value: progress)
                        .frame(width: 280)
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(OnboardingStyle.muted)
                    Button("Cancel") { library.cancelDownload(spec) }
                        .buttonStyle(.plain)
                        .foregroundStyle(OnboardingStyle.ink)
                }
                .font(.system(size: 13, weight: .medium))
                ContinueButton(model: model)
            } else if library.activeModel?.id == spec.id {
                ContinueButton(model: model)
            } else if library.isInstalled(spec) {
                Button("Use \(spec.displayName)", action: model.downloadChosenModel)
                    .buttonStyle(OnboardingButtonStyle())
            } else {
                Button("Download \(spec.sizeBytes.formatted(.byteCount(style: .file)))", action: model.downloadChosenModel)
                    .buttonStyle(OnboardingButtonStyle())
            }
            if let error = library.downloadErrors[spec.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if library.mayExceedMemory(spec) {
                Label("This model may be too large for this Mac\u{2019}s memory.", systemImage: "memorychip")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 13, weight: .medium))
    }
}

struct PersonalStep: View {
    let model: OnboardingModel
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        VStack(spacing: 28) {
            OnboardingPanel {
                OnboardingRow(title: "Your name", detail: "Used when a suggestion needs your name.") {
                    TextField("Name", text: $preferences.userName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .padding(.horizontal, 10)
                        .frame(width: 220, height: 32)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 9))
                }
                OnboardingDivider()
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingRow(title: "About you", detail: "Who you write to and how. Every suggestion follows it.") {}
                        .padding(.bottom, -10)
                    TextEditor(text: $preferences.customInstructions)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 76)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 9))
                        .overlay(alignment: .topLeading) {
                            if preferences.customInstructions.isEmpty {
                                Text("For example: I write to clients in English and Arabic. Warm and direct, short sentences.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(OnboardingStyle.muted.opacity(0.7))
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .padding(.bottom, 14)
                }
                OnboardingDivider()
                OnboardingRow(title: "Learn from what you write",
                              detail: "Keeps the text of fields where it suggests, on this Mac only. Never password fields.") {
                    Toggle("", isOn: $preferences.recordWriting).labelsHidden().toggleStyle(.switch)
                }
                OnboardingDivider()
                OnboardingRow(title: "Fix obvious typos as you type",
                              detail: "In English, French, German and Spanish. Press Delete right after to keep your word.") {
                    Toggle("", isOn: $preferences.autoFixTypos).labelsHidden().toggleStyle(.switch)
                        .disabled(!preferences.typoFixesEnabled)
                }
            }
            ContinueButton(model: model)
        }
    }
}

struct ContextStep: View {
    let model: OnboardingModel
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var preferences = preferences
        VStack(spacing: 28) {
            OnboardingPanel {
                OnboardingRow(title: "Use text from the window",
                              detail: "Such as the message you\u{2019}re replying to. Used for the next suggestion only, never stored.") {
                    Toggle("", isOn: $preferences.screenContextEnabled).labelsHidden().toggleStyle(.switch)
                }
                OnboardingDivider()
                OnboardingRow(title: "Read text from screenshots",
                              detail: "For apps that hide their text. Needs Screen Recording.") {
                    Toggle("", isOn: Binding(
                        get: { preferences.ocrEnabled },
                        set: { isOn in
                            preferences.ocrEnabled = isOn
                            if isOn, !appState.screenRecordingGranted { model.guide(.screenRecording) }
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                }
                if preferences.ocrEnabled {
                    if appState.screenRecordingGranted {
                        PermissionNote(text: ScreenCaptureNotice.text, isGranted: true) {}
                    } else if appState.screenRecordingAllowedInSettings {
                        PermissionNote(text: "Allowed. Ghostwriter has to reopen to use it, then setup continues here.", isGranted: false) {
                            Button("Quit & Reopen", action: Relauncher.relaunch)
                        }
                    } else if model.guidedTopics.contains(.screenRecording) {
                        PermissionNote(text: "Turn on Ghostwriter in the list. This updates by itself.", isGranted: false) {
                            Button("Open System Settings") { model.guide(.screenRecording) }
                        }
                    } else {
                        PermissionNote(text: "Allow Ghostwriter under Screen & System Audio Recording.", isGranted: false) {
                            Button("Open System Settings") { model.guide(.screenRecording) }
                        }
                    }
                }
                OnboardingDivider()
                OnboardingRow(title: "Use text you copied",
                              detail: "From the last few minutes. Passwords are skipped.") {
                    Toggle("", isOn: Binding(
                        get: { preferences.clipboardContextEnabled },
                        set: { isOn in
                            preferences.clipboardContextEnabled = isOn
                            if isOn, !appState.clipboardAccessAllowed { ClipboardReader.requestAccess() }
                        }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                }
                if preferences.clipboardContextEnabled {
                    PermissionNote(text: appState.clipboardAccessAllowed ? nil : "Choose Always Allow for Ghostwriter under Paste from Other Apps.",
                                   isGranted: appState.clipboardAccessAllowed) {
                        Button("Open System Settings") { model.guide(.pasteboard) }
                    }
                }
            }
            ContinueButton(model: model)
        }
    }
}

private struct PermissionNote<Actions: View>: View {
    let text: String?
    let isGranted: Bool
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if isGranted { Allowed() }
            if let text {
                Text(text).foregroundStyle(OnboardingStyle.muted)
            }
            if !isGranted {
                Spacer(minLength: 0)
                HStack(spacing: 14) { actions }
                    .buttonStyle(.plain)
                    .foregroundStyle(OnboardingStyle.ink)
                    .fixedSize()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 14)
    }
}

struct PracticeStep: View {
    let model: OnboardingModel
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            PracticeField(text: $text, placeholder: "Hi Sam, thanks for sending the", font: .system(size: 20), padding: 14)
                .frame(width: 640, height: 150)
                .focused($focused)
            if let status {
                Label(status, systemImage: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnboardingStyle.muted)
            }
            HStack(spacing: 22) {
                ForEach(tasks, id: \.label) { task in
                    let done = appState.practiceAcceptances.contains(task.kind)
                    HStack(spacing: 8) {
                        OnboardingKeycap(label: task.key)
                        Text(task.label)
                            .foregroundStyle(done ? OnboardingStyle.ink : OnboardingStyle.muted)
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                            .opacity(done ? 1 : 0)
                    }
                    .animation(.easeOut(duration: 0.2), value: done)
                }
            }
            .font(.system(size: 13, weight: .medium))
            if appState.macOSPredictionsEnabled {
                HStack(spacing: 10) {
                    Text("macOS shows its own grey predictions too, and they compete.")
                        .foregroundStyle(OnboardingStyle.muted)
                    Button("Turn Them Off\u{2026}", action: SystemSettings.keyboard.open)
                        .buttonStyle(.plain)
                        .foregroundStyle(OnboardingStyle.ink)
                }
                .font(.system(size: 13, weight: .medium))
            }
            Button("Continue", action: model.advance)
                .buttonStyle(OnboardingButtonStyle(prominent: !appState.practiceAcceptances.isEmpty))
        }
        .onAppear {
            appState.practiceAcceptances = []
            focused = true
        }
        .onChange(of: appState.practiceAcceptances) {
            if !appState.practiceAcceptances.isEmpty { model.completeHeadline(thenAdvance: false) }
        }
    }

    private var tasks: [(key: String, label: String, kind: AcceptanceEvent.Kind)] {
        var tasks: [(key: String, label: String, kind: AcceptanceEvent.Kind)] = [
            (preferences.acceptWordKey.displayName, "Take a word", .word),
            (preferences.acceptFullKey.displayName, "Take it all", .full),
        ]
        if preferences.draftEnabled, let shortcut = KeyboardShortcuts.getShortcut(for: .longDraft) {
            tasks.append((shortcut.description, "Write on", .draft))
        }
        if preferences.selectionActionsEnabled, appState.foundationModelsUnavailableReason == nil,
           let shortcut = KeyboardShortcuts.getShortcut(for: .selectionActions) {
            tasks.append((shortcut.description, "Rewrite a selection", .action))
        }
        return tasks
    }

    private var status: String? {
        if !appState.accessibilityGranted { return "Suggestions appear here once Accessibility access is allowed." }
        switch appState.modelStatus {
        case .ready: return nil
        case .downloading(let progress):
            return "Suggestions start when the model is downloaded (\(progress.formatted(.percent.precision(.fractionLength(0)))))."
        case .loading: return "The model is loading."
        case .notInstalled: return "Download a model to see suggestions."
        case .failed(let message): return "The model failed to load: \(message)"
        }
    }
}

struct DoneStep: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var preferences = preferences
        VStack(spacing: 28) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                ForEach(keys, id: \.label) { key in
                    GridRow {
                        OnboardingKeycap(label: key.key)
                            .gridColumnAlignment(.trailing)
                        Text(key.label)
                            .foregroundStyle(OnboardingStyle.inkSoft)
                    }
                }
            }
            .font(.system(size: 15, weight: .medium))
            OnboardingPanel {
                OnboardingRow(title: "Open at login", detail: "Ghostwriter lives in the menu bar.") {
                    if preferences.launchAtLoginNeedsApproval {
                        Button("Open Login Items\u{2026}") { SMAppService.openSystemSettingsLoginItems() }
                    } else {
                        Toggle("", isOn: $preferences.launchAtLogin).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
        .task {
            preferences.refreshLaunchAtLogin()
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                preferences.refreshLaunchAtLogin()
            }
        }
    }

    private var keys: [(key: String, label: String)] {
        var keys = [
            (preferences.acceptWordKey.displayName, "Take the next word"),
            (preferences.acceptFullKey.displayName, "Take the whole suggestion"),
            ("\u{2325}Tab", "Type a real Tab"),
            ("esc", "Hide a suggestion"),
        ]
        let shortcuts: [(KeyboardShortcuts.Name, String, Bool)] = [
            (.longDraft, "Write a longer draft", preferences.draftEnabled),
            (.selectionActions, "Rewrite selected text",
             preferences.selectionActionsEnabled && appState.foundationModelsUnavailableReason == nil),
            (.toggleCompletions, "Turn suggestions off or on", true),
        ]
        for (name, label, enabled) in shortcuts where enabled {
            if let shortcut = KeyboardShortcuts.getShortcut(for: name) { keys.append((shortcut.description, label)) }
        }
        return keys
    }
}
