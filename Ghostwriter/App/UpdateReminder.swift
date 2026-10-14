import Foundation
import Sparkle

final class UpdateReminder: NSObject, SPUStandardUserDriverDelegate {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        appState.availableUpdate = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        appState.availableUpdate = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        appState.availableUpdate = nil
    }
}
