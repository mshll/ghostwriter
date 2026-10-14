import ScreenContext
import SwiftUI

extension View {
    /// Re-reads permission state every second while the view is visible. With `preferences`, also makes the
    /// first screen capture once Screen Recording is allowed and screenshots are on, so macOS asks the user to
    /// confirm it here and not later over their writing.
    func pollsPermissions(_ appState: AppState, confirmingCaptureFor preferences: Preferences? = nil) -> some View {
        task {
            while !Task.isCancelled {
                appState.refreshPermissions()
                if let preferences, !preferences.hasConfirmedScreenCapture, preferences.ocrEnabled,
                   appState.screenRecordingGranted, await ScreenRecordingPermission.confirmWithSystem() {
                    preferences.hasConfirmedScreenCapture = true
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }
}

struct PermissionStatusRow: View {
    let title: String
    var subtitle: String? = nil
    let isGranted: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        LabeledContent {
            if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Button("Allow\u{2026}", action: request)
                    Button("Open System Settings", action: openSettings)
                }
            }
        } label: {
            Text(title)
            if let subtitle {
                Text(subtitle)
            }
        }
    }
}

enum ScreenCaptureNotice {
    static let text = "The first time Ghostwriter reads the screen, macOS asks whether it may \u{201C}bypass the system private window picker.\u{201D} Choose Allow. macOS asks again only after a month without screenshots."
}
