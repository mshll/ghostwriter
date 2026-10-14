import ScreenContext
import SwiftUI

struct ContextPane: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPaneView(pane: .context) {
            Section {
                SettingRow(ContextSetting.windowText, isOn: $preferences.screenContextEnabled)
            } header: {
                Text("Window text")
            }

            Section {
                PermissionStatusRow(
                    ContextSetting.screenRecording,
                    isGranted: appState.screenRecordingGranted,
                    request: ScreenRecordingPermission.request,
                    openSettings: SystemSettings.screenRecording.open
                )
                .settingsSearchTarget(ContextSetting.screenRecording)
                SettingRow(ContextSetting.screenshots, isOn: $preferences.ocrEnabled)
                .disabled(!appState.screenRecordingGranted)
            } header: {
                Text("Screenshots")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !appState.screenRecordingGranted {
                        Text("After allowing Screen Recording, macOS may ask you to quit and reopen Ghostwriter.")
                    }
                    Text("Screenshots show only the window you\u{2019}re typing in. \(ScreenCaptureNotice.text)")
                }
            }

            Section {
                SettingRow(ContextSetting.clipboard, isOn: $preferences.clipboardContextEnabled)
                if preferences.clipboardContextEnabled {
                    PermissionStatusRow(
                        ContextSetting.pasteFromOtherApps,
                        isGranted: appState.clipboardAccessAllowed,
                        request: ClipboardReader.requestAccess,
                        openSettings: SystemSettings.pasteboard.open
                    )
                    .settingsSearchTarget(ContextSetting.pasteFromOtherApps)
                }
            } header: {
                Text("Clipboard")
            } footer: {
                if preferences.clipboardContextEnabled, !appState.clipboardAccessAllowed {
                    Text("Ghostwriter reads the clipboard only when macOS always allows it, so suggestions never show a paste alert. Click Allow\u{2026} once so macOS lists Ghostwriter, then choose Always Allow for it in System Settings.")
                }
            }
        }
        .pollsPermissions(appState, confirmingCaptureFor: preferences)
    }
}

enum ContextSetting: SettingKey {
    case windowText, screenRecording, screenshots, clipboard, pasteFromOtherApps

    var text: SettingText {
        switch self {
        case .windowText: SettingText("Use text from the window you\u{2019}re typing in", subtitle: "Ghostwriter reads the visible text near your cursor, such as the message you\u{2019}re replying to, through Accessibility. It is used for the next suggestion only and never stored.", keywords: ["accessibility", "screen", "reply"])
        case .screenRecording: SettingText("Screen Recording", keywords: ["permission", "privacy"])
        case .screenshots: SettingText("Read text from screenshots when needed", subtitle: "Some apps don\u{2019}t expose their text to Accessibility. With Screen Recording allowed, Ghostwriter can recognize the text in a screenshot of the window instead. Suggestions in the middle of a line also use a screenshot to match the field\u{2019}s background. Screenshots stay in memory and are discarded right away.", keywords: ["ocr", "screen", "capture"])
        case .clipboard: SettingText("Use text you copied recently", subtitle: "Text you copied in the last few minutes helps when you paste a question and answer it. Passwords and other concealed clipboard items are skipped.", keywords: ["clipboard", "pasteboard", "copy"])
        case .pasteFromOtherApps: SettingText("Paste from other apps", keywords: ["permission", "clipboard"])
        }
    }
}
