import AppKit
import Sparkle
import SwiftUI

struct UpdatesPane: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        UpdatesForm(updater: services.updaterController.updater)
    }
}

private struct UpdatesForm: View {
    let updater: SPUUpdater
    @State private var checksAutomatically: Bool
    @State private var downloadsAutomatically: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _checksAutomatically = State(initialValue: updater.automaticallyChecksForUpdates)
        _downloadsAutomatically = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        SettingsPaneView(pane: .updates) {
            Section {
                SettingRow(UpdatesSetting.autoCheck) {
                    Toggle("Check for updates automatically", isOn: $checksAutomatically)
                        .onChange(of: checksAutomatically) { _, on in
                            updater.automaticallyChecksForUpdates = on
                        }
                }
                SettingRow(UpdatesSetting.autoDownload) {
                    Toggle("Download updates in the background", isOn: $downloadsAutomatically)
                        .onChange(of: downloadsAutomatically) { _, on in
                            updater.automaticallyDownloadsUpdates = on
                        }
                }
                .disabled(!checksAutomatically || !updater.allowsAutomaticUpdates)
                SettingRow(UpdatesSetting.lastChecked, subtitle: lastChecked) {
                    Button("Check Now") {
                        NSApp.activate()
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
    }

    private var lastChecked: String {
        guard let date = updater.lastUpdateCheckDate else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }
}

enum UpdatesSetting: SettingKey {
    case autoCheck, autoDownload, lastChecked

    var text: SettingText {
        switch self {
        case .autoCheck: SettingText("Check for updates automatically", keywords: ["sparkle", "version"])
        case .autoDownload: SettingText("Download updates in the background", subtitle: "Ghostwriter still asks before it installs one.", keywords: ["sparkle"])
        case .lastChecked: SettingText("Last checked", keywords: ["check now", "version"])
        }
    }
}
