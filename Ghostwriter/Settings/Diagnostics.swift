import Actions
import Darwin
import Foundation
import GWCore
import Inference

/// A plain-text summary for bug reports: the Mac, the app's state and its settings. Never any text the user wrote.
enum Diagnostics {
    static func report(preferences: Preferences, appState: AppState, models: ModelLibrary) -> String {
        let hardware = models.hardware
        return """
            Ghostwriter \(AppVersion.label)
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString.replacing("Version ", with: ""))
            Mac: \(macModel), \(hardware.chip.isEmpty ? "Apple silicon" : hardware.chip), \(hardware.memoryGB) GB
            Model: \(models.activeModel?.displayName ?? "none"), \(appState.modelStatus.diagnosticLabel)
            Accessibility: \(onOff(appState.accessibilityGranted)), Screen Recording: \(onOff(appState.screenRecordingGranted)), \
            Paste from other apps: \(onOff(appState.clipboardAccessAllowed)), macOS inline predictions: \(onOff(appState.macOSPredictionsEnabled))
            Suggestions: \(onOff(preferences.completionsEnabled)), length \(preferences.completionLength.title), \
            inside text \(onOff(preferences.midLineEnabled)), drafts \(onOff(preferences.draftEnabled)), \
            typo fixes \(onOff(preferences.typoFixesEnabled)), auto-fix \(onOff(preferences.autoFixTypos)), sentence check \(onOff(preferences.sentenceTypoCheck)), emoji \(onOff(preferences.emojiEnabled))
            Context: window text \(onOff(preferences.screenContextEnabled)), screenshots \(onOff(preferences.ocrEnabled)), \
            clipboard \(onOff(preferences.clipboardContextEnabled))
            Personalization: learning \(onOff(preferences.recordWriting)), strength \(preferences.personalizationStrength)
            Battery: on demand \(onOff(preferences.batteryOnDemandOnly)), shorter \(onOff(preferences.batteryShorterCompletions)), \
            smaller model \(onOff(preferences.batterySmallerModel))
            Selection actions: \(onOff(preferences.selectionActionsEnabled)), proofread \(onOff(preferences.proofreadEnabled)), Apple Intelligence \(WritingAssistant.isAvailable ? "available" : "unavailable")
            Database: \(appState.databaseError == nil ? "ok" : "unavailable")
            """
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

enum AppVersion {
    static var label: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

extension ModelStatus {
    fileprivate var diagnosticLabel: String {
        switch self {
        case .notInstalled: "not installed"
        case .downloading: "downloading"
        case .loading: "loading"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        }
    }
}
