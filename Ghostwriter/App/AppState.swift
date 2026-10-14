import AppKit
import Capture
import GWCore
import Memory
import Observation
import ScreenContext
import os

enum PauseState: Equatable {
    case until(Date)
    case untilAppSwitch

    var isActive: Bool {
        if case .until(let end) = self { return end > .now }
        return true
    }
}

extension PauseState {
    func summary(scope: String) -> String {
        switch self {
        case .until(let end):
            let minutes = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
            return "Paused \(scope) for \(minutes) more minute\(minutes == 1 ? "" : "s")"
        case .untilAppSwitch:
            return "Paused \(scope) until you switch apps"
        }
    }
}

enum PauseDuration: CaseIterable {
    case fiveMinutes, fifteenMinutes, oneHour

    var title: String {
        switch self {
        case .fiveMinutes: "For 5 Minutes"
        case .fifteenMinutes: "For 15 Minutes"
        case .oneHour: "For 1 Hour"
        }
    }

    var pause: PauseState {
        switch self {
        case .fiveMinutes: .until(.now.addingTimeInterval(5 * 60))
        case .fifteenMinutes: .until(.now.addingTimeInterval(15 * 60))
        case .oneHour: .until(.now.addingTimeInterval(60 * 60))
        }
    }
}

enum ModelStatus: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case loading
    case ready(name: String)
    case failed(message: String)
}

struct AttentionIssue: Identifiable, Equatable {
    enum Kind: String {
        case accessibility, noModel, modelFailed, secureInput, macOSPredictions, foundationModelsUnavailable,
            databaseUnavailable
    }

    enum Severity: Comparable {
        case info, warning, critical
    }

    var kind: Kind
    var title: String
    var severity: Severity

    var id: Kind { kind }
}

@Observable
final class AppState {
    private static let log = Logger.gw("AppState")

    var globalPause: PauseState? {
        didSet { scheduleExpiry(of: globalPause) }
    }
    private(set) var appPauses: [String: PauseState] = [:]

    var frontmostApp: AppIdentity? {
        didSet {
            guard frontmostApp?.bundleID != oldValue?.bundleID else { return }
            clearAppSwitchPauses()
        }
    }
    var lastFieldApp: AppIdentity?

    var modelStatus: ModelStatus = .notInstalled
    var accessibilityGranted = false
    var screenRecordingGranted = false
    var screenRecordingAllowedInSettings = false {
        didSet {
            guard screenRecordingAllowedInSettings != oldValue else { return }
            Self.log.info("Screen Recording allowed in settings: \(self.screenRecordingAllowedInSettings), usable: \(self.screenRecordingGranted)")
        }
    }
    var clipboardAccessAllowed = false
    var macOSPredictionsEnabled = false
    var secureInputActive = false
    var wordsToday = 0
    var availableUpdate: String?
    var practiceFieldVisible = false
    var practiceAcceptances: Set<AcceptanceEvent.Kind> = []
    var foundationModelsUnavailableReason: String?
    var databaseError: String?

    var isGloballyPaused: Bool { globalPause?.isActive ?? false }

    func isPaused(bundleID: String?) -> Bool {
        if isGloballyPaused { return true }
        guard let bundleID, let pause = appPauses[bundleID] else { return false }
        return pause.isActive
    }

    func pause(bundleID: String, _ pause: PauseState) {
        appPauses[bundleID] = pause
        scheduleExpiry(of: pause)
    }

    func resume(bundleID: String) {
        appPauses[bundleID] = nil
    }

    func refreshPermissions() {
        accessibilityGranted = AccessibilityPermission.isGranted
        screenRecordingGranted = ScreenRecordingPermission.isGranted
        screenRecordingAllowedInSettings = ScreenRecordingPermission.isAllowedInSettings
        clipboardAccessAllowed = ClipboardReader.accessAllowed
        macOSPredictionsEnabled = NSSpellChecker.isAutomaticInlinePredictionEnabled
        secureInputActive = SecureInput.isEnabled
    }

    var attentionIssues: [AttentionIssue] {
        var issues: [AttentionIssue] = []
        if !accessibilityGranted {
            issues.append(AttentionIssue(kind: .accessibility, title: "Ghostwriter needs Accessibility access", severity: .critical))
        }
        switch modelStatus {
        case .notInstalled:
            issues.append(AttentionIssue(kind: .noModel, title: "No AI model installed yet", severity: .critical))
        case .failed(let message):
            issues.append(AttentionIssue(kind: .modelFailed, title: "The AI model failed to load: \(message)", severity: .critical))
        case .downloading, .loading, .ready:
            break
        }
        if secureInputActive {
            issues.append(AttentionIssue(kind: .secureInput, title: "Secure Input is on and blocks Ghostwriter's keys", severity: .warning))
        }
        if macOSPredictionsEnabled {
            issues.append(AttentionIssue(kind: .macOSPredictions, title: "macOS inline predictions compete with Ghostwriter", severity: .info))
        }
        if let databaseError {
            issues.append(AttentionIssue(kind: .databaseUnavailable, title: "Writing history unavailable: \(databaseError)", severity: .warning))
        }
        if foundationModelsUnavailableReason != nil {
            issues.append(AttentionIssue(kind: .foundationModelsUnavailable, title: "Selection actions are unavailable", severity: .info))
        }
        return issues
    }

    var needsAttention: Bool {
        attentionIssues.contains { $0.severity >= .warning }
    }

    private func clearAppSwitchPauses() {
        appPauses = appPauses.filter { $0.value != .untilAppSwitch }
        if globalPause == .untilAppSwitch { globalPause = nil }
    }

    private func scheduleExpiry(of pause: PauseState?) {
        guard case .until(let end) = pause else { return }
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(end.timeIntervalSinceNow, 0) + 0.5))
            } catch {
                return
            }
            self?.removeExpiredPauses()
        }
    }

    private func removeExpiredPauses() {
        if let globalPause, !globalPause.isActive { self.globalPause = nil }
        appPauses = appPauses.filter { $0.value.isActive }
    }
}
