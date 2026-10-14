import AppKit
import Capture
import ScreenContext
import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState
    @Environment(\.replayOnboarding) private var replayOnboarding
    @State private var isConfirmingHideIcon = false

    var body: some View {
        @Bindable var preferences = preferences
        SettingsPaneView(pane: .general) {
            Section {
                SettingRow(GeneralSetting.openAtLogin, isOn: $preferences.launchAtLogin)
                if preferences.launchAtLoginNeedsApproval {
                    SettingRow(GeneralSetting.waitingForApproval) {
                        Button("Open Login Items\u{2026}") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }

            Section {
                SettingRow(GeneralSetting.menuBarIcon) {
                    Toggle("Show icon in menu bar", isOn: Binding(
                        get: { preferences.showsMenuBarIcon },
                        set: { shows in
                            if shows {
                                preferences.showsMenuBarIcon = true
                            } else {
                                isConfirmingHideIcon = true
                            }
                        }
                    ))
                }
                SettingRow(GeneralSetting.wordCount, isOn: $preferences.showWordCountInMenuBar)
                .disabled(!preferences.showsMenuBarIcon)
            }
            .alert("Hide the menu bar icon?", isPresented: $isConfirmingHideIcon) {
                Button("Hide") { preferences.showsMenuBarIcon = false }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Ghostwriter keeps suggesting, but warnings such as a missing permission no longer show in the menu bar. To come back here, open Ghostwriter again from Finder or Spotlight.")
            }

            Section {
                PermissionStatusRow(
                    GeneralSetting.accessibility,
                    isGranted: appState.accessibilityGranted,
                    request: AccessibilityPermission.request,
                    openSettings: SystemSettings.accessibility.open
                )
                .settingsSearchTarget(GeneralSetting.accessibility)
                PermissionStatusRow(
                    GeneralSetting.screenRecording,
                    isGranted: appState.screenRecordingGranted,
                    request: ScreenRecordingPermission.request,
                    openSettings: SystemSettings.screenRecording.open
                )
                .settingsSearchTarget(GeneralSetting.screenRecording)
                PermissionStatusRow(
                    GeneralSetting.pasteFromOtherApps,
                    isGranted: appState.clipboardAccessAllowed,
                    request: ClipboardReader.requestAccess,
                    openSettings: SystemSettings.pasteboard.open
                )
                .settingsSearchTarget(GeneralSetting.pasteFromOtherApps)
                SettingRow(GeneralSetting.macOSPredictions) {
                    if appState.macOSPredictionsEnabled {
                        Button("Open Keyboard Settings", action: SystemSettings.keyboard.open)
                    } else {
                        Label("Off", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            } header: {
                Text("Setup")
            }

            Section {
                SettingRow(GeneralSetting.onboarding) {
                    Button("Replay Onboarding", action: replayOnboarding)
                }
            }
        }
        .pollsPermissions(appState)
        .task {
            preferences.refreshLaunchAtLogin()
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                preferences.refreshLaunchAtLogin()
            }
        }
    }
}

enum GeneralSetting: SettingKey {
    case openAtLogin, waitingForApproval, menuBarIcon, wordCount, accessibility, screenRecording, pasteFromOtherApps, macOSPredictions, onboarding

    var text: SettingText {
        switch self {
        case .openAtLogin: SettingText("Open at login", subtitle: "Start Ghostwriter when you log in.", keywords: ["startup", "launch", "login items"])
        case .waitingForApproval: SettingText("Waiting for approval", subtitle: "Allow Ghostwriter under Login Items in System Settings.", keywords: ["login items"])
        case .menuBarIcon: SettingText("Show icon in menu bar", subtitle: "Ghostwriter keeps running either way.")
        case .wordCount: SettingText("Word count in the menu bar", subtitle: "Shows the words Ghostwriter wrote for you today in place of the icon.", keywords: ["menubar", "status bar", "icon"])
        case .accessibility: SettingText("Accessibility", subtitle: "Required. Lets Ghostwriter read the field you type in and show suggestions there.", keywords: ["permission", "privacy", "setup"])
        case .screenRecording: SettingText("Screen Recording", subtitle: "Optional. Reads text from apps that hide it from Accessibility.", keywords: ["permission", "privacy", "screenshot", "setup"])
        case .pasteFromOtherApps: SettingText("Paste from other apps", subtitle: "Optional. Lets suggestions use text you copied.", keywords: ["permission", "clipboard", "pasteboard", "setup"])
        case .macOSPredictions: SettingText("macOS inline predictions", subtitle: "macOS can show its own grey predictions, which compete with Ghostwriter. Turn off \u{201C}Show inline predictive text\u{201D} in Keyboard \u{203A} Text Input \u{203A} Edit.", keywords: ["predictive text", "keyboard", "conflict", "setup"])
        case .onboarding: SettingText("Onboarding", subtitle: "The welcome and setup from the first launch.", keywords: ["welcome", "setup", "replay", "tour"])
        }
    }
}
