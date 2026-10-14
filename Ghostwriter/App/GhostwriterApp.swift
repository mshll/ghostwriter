import Sparkle
import SwiftUI

@main
struct GhostwriterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") {
                    appDelegate.services.updaterController.checkForUpdates(nil)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    appDelegate.windows.showSettings()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
