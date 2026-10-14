import Actions
import AppKit
import GWCore
import Input
import KeyboardShortcuts
import Observation
import ServiceManagement
import os

enum EscapeBehavior: String, CaseIterable, Identifiable {
    case pauseBriefly, offUntilAppSwitch, passToApp

    var id: Self { self }

    var title: String {
        switch self {
        case .pauseBriefly: "Hide it and pause for a few seconds"
        case .offUntilAppSwitch: "Hide it and pause until I switch apps"
        case .passToApp: "Leave Escape to the app"
        }
    }
}

/// User settings, persisted in `UserDefaults` under `ghostwriter.<propertyName>`.
@Observable
final class Preferences {
    static let keyPrefix = "ghostwriter."
    static let personalizationRange = 0...5
    private static let log = Logger.gw("Preferences")

    @ObservationIgnored private let defaults: UserDefaults
    private var revision = 0
    private var launchAtLoginStatus: SMAppService.Status

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    var completionsEnabled: Bool {
        get { value(\.completionsEnabled, default: true) }
        set { setValue(newValue, \.completionsEnabled) }
    }

    var completionLength: CompletionLength {
        get { value(\.completionLength, default: .medium) }
        set { setValue(newValue, \.completionLength) }
    }

    var midLineEnabled: Bool {
        get { value(\.midLineEnabled, default: true) }
        set { setValue(newValue, \.midLineEnabled) }
    }

    var emojiEnabled: Bool {
        get { value(\.emojiEnabled, default: true) }
        set { setValue(newValue, \.emojiEnabled) }
    }

    var typoFixesEnabled: Bool {
        get { value(\.typoFixesEnabled, default: true) }
        set { setValue(newValue, \.typoFixesEnabled) }
    }

    var suppressOnTypo: Bool {
        get { value(\.suppressOnTypo, default: true) }
        set { setValue(newValue, \.suppressOnTypo) }
    }

    var autoFixTypos: Bool {
        get { value(\.autoFixTypos, default: false) }
        set { setValue(newValue, \.autoFixTypos) }
    }

    var sentenceTypoCheck: Bool {
        get { value(\.sentenceTypoCheck, default: true) }
        set { setValue(newValue, \.sentenceTypoCheck) }
    }

    /// Lowercased.
    var ignoredTypoWords: [String] {
        get { value(\.ignoredTypoWords, default: []) }
        set { setValue(newValue, \.ignoredTypoWords) }
    }

    func ignoreTypo(_ word: String) {
        let lowered = word.lowercased()
        guard !ignoredTypoWords.contains(lowered) else { return }
        ignoredTypoWords = (ignoredTypoWords + [lowered]).sorted()
    }

    var draftEnabled: Bool {
        get { value(\.draftEnabled, default: true) }
        set { setValue(newValue, \.draftEnabled) }
    }

    var overlayOpacity: Double {
        get { value(\.overlayOpacity, default: 0.45) }
        set { setValue(newValue, \.overlayOpacity) }
    }

    var acceptFullKey: HotKey {
        get { value(\.acceptFullKey, default: HotKey(keyCode: UInt32(KeyboardLayout.keyAboveTab))) }
        set { setValue(newValue, \.acceptFullKey) }
    }

    var acceptWordKey: HotKey {
        get { value(\.acceptWordKey, default: HotKey(keyCode: HotKey.tabKeyCode)) }
        set { setValue(newValue, \.acceptWordKey) }
    }

    var includeTrailingPunctuation: Bool {
        get { value(\.includeTrailingPunctuation, default: true) }
        set { setValue(newValue, \.includeTrailingPunctuation) }
    }

    var includeTrailingSpace: Bool {
        get { value(\.includeTrailingSpace, default: false) }
        set { setValue(newValue, \.includeTrailingSpace) }
    }

    var escapeBehavior: EscapeBehavior {
        get { value(\.escapeBehavior, default: .pauseBriefly) }
        set { setValue(newValue, \.escapeBehavior) }
    }

    var screenContextEnabled: Bool {
        get { value(\.screenContextEnabled, default: true) }
        set { setValue(newValue, \.screenContextEnabled) }
    }

    var ocrEnabled: Bool {
        get { value(\.ocrEnabled, default: false) }
        set { setValue(newValue, \.ocrEnabled) }
    }

    var clipboardContextEnabled: Bool {
        get { value(\.clipboardContextEnabled, default: false) }
        set { setValue(newValue, \.clipboardContextEnabled) }
    }

    var recordWriting: Bool {
        get { value(\.recordWriting, default: true) }
        set { setValue(newValue, \.recordWriting) }
    }

    var personalizationStrength: Int {
        get { value(\.personalizationStrength, default: 3) }
        set { setValue(newValue.clamped(to: Self.personalizationRange), \.personalizationStrength) }
    }

    var customInstructions: String {
        get { value(\.customInstructions, default: "") }
        set { setValue(newValue, \.customInstructions) }
    }

    var userName: String {
        get { value(\.userName, default: NSFullUserName()) }
        set { setValue(newValue, \.userName) }
    }

    var selectionActionsEnabled: Bool {
        get { value(\.selectionActionsEnabled, default: true) }
        set { setValue(newValue, \.selectionActionsEnabled) }
    }

    var proofreadEnabled: Bool {
        get { value(\.proofreadEnabled, default: true) }
        set { setValue(newValue, \.proofreadEnabled) }
    }

    var showsSelectionActionsOnSelect: Bool {
        get { value(\.showsSelectionActionsOnSelect, default: false) }
        set { setValue(newValue, \.showsSelectionActionsOnSelect) }
    }

    var enabledActions: Set<WritingAction> {
        get { value(\.enabledActions, default: Set(WritingAction.allCases)) }
        set { setValue(newValue, \.enabledActions) }
    }

    var translateTargetLanguage: String {
        get { value(\.translateTargetLanguage, default: "English") }
        set { setValue(newValue, \.translateTargetLanguage) }
    }

    var batteryOnDemandOnly: Bool {
        get { value(\.batteryOnDemandOnly, default: false) }
        set { setValue(newValue, \.batteryOnDemandOnly) }
    }

    var batteryShorterCompletions: Bool {
        get { value(\.batteryShorterCompletions, default: false) }
        set { setValue(newValue, \.batteryShorterCompletions) }
    }

    var batterySmallerModel: Bool {
        get { value(\.batterySmallerModel, default: false) }
        set { setValue(newValue, \.batterySmallerModel) }
    }

    var selectedModelID: String? {
        get { value(\.selectedModelID, default: nil) }
        set { setValue(newValue, \.selectedModelID) }
    }

    var showsMenuBarIcon: Bool {
        get { value(\.showsMenuBarIcon, default: true) }
        set { setValue(newValue, \.showsMenuBarIcon) }
    }

    var showWordCountInMenuBar: Bool {
        get { value(\.showWordCountInMenuBar, default: true) }
        set { setValue(newValue, \.showWordCountInMenuBar) }
    }

    var settingsPane: SettingsPane {
        get { value(\.settingsPane, default: .general) }
        set { setValue(newValue, \.settingsPane) }
    }

    var hasCompletedOnboarding: Bool {
        get { value(\.hasCompletedOnboarding, default: false) }
        set { setValue(newValue, \.hasCompletedOnboarding) }
    }

    var onboardingStep: OnboardingStep? {
        get { value(\.onboardingStep, default: nil) }
        set { setValue(newValue, \.onboardingStep) }
    }

    var hasConfirmedScreenCapture: Bool {
        get { value(\.hasConfirmedScreenCapture, default: false) }
        set { setValue(newValue, \.hasConfirmedScreenCapture) }
    }

    var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Self.log.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            }
            launchAtLoginStatus = SMAppService.mainApp.status
        }
    }

    var launchAtLoginNeedsApproval: Bool { launchAtLoginStatus == .requiresApproval }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        if status != launchAtLoginStatus { launchAtLoginStatus = status }
    }

    func resetAll() {
        let onboarded = hasCompletedOnboarding
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            defaults.removeObject(forKey: key)
        }
        KeyboardShortcuts.reset(KeyboardShortcuts.Name.global)
        revision += 1
        hasCompletedOnboarding = onboarded
    }

    func restoreDefaultAcceptKeys() {
        removeValue(\.acceptFullKey, key: "acceptFullKey")
        removeValue(\.acceptWordKey, key: "acceptWordKey")
    }

    private func removeValue<T>(_ keyPath: KeyPath<Preferences, T>, key: String) {
        withMutation(keyPath: keyPath) {
            defaults.removeObject(forKey: Self.keyPrefix + key)
        }
    }

    private func value<T: PreferenceValue>(_ keyPath: KeyPath<Preferences, T>, default defaultValue: T, key: String = #function) -> T {
        access(keyPath: keyPath)
        _ = revision
        guard let stored = defaults.object(forKey: Self.keyPrefix + key) else { return defaultValue }
        return T(storedValue: stored) ?? defaultValue
    }

    private func setValue<T: PreferenceValue>(_ newValue: T, _ keyPath: KeyPath<Preferences, T>, key: String = #function) {
        withMutation(keyPath: keyPath) {
            if let stored = newValue.storedValue {
                defaults.set(stored, forKey: Self.keyPrefix + key)
            } else {
                defaults.removeObject(forKey: Self.keyPrefix + key)
            }
        }
    }
}

extension HotKey {
    static let tabKeyCode: UInt32 = 48
}

protocol PreferenceValue {
    init?(storedValue: Any)
    /// Property-list representation; nil removes the key.
    var storedValue: Any? { get }
}

extension Bool: PreferenceValue {
    init?(storedValue: Any) {
        guard let value = storedValue as? Bool else { return nil }
        self = value
    }

    var storedValue: Any? { self }
}

extension Int: PreferenceValue {
    init?(storedValue: Any) {
        guard let value = storedValue as? Int else { return nil }
        self = value
    }

    var storedValue: Any? { self }
}

extension Double: PreferenceValue {
    init?(storedValue: Any) {
        guard let value = storedValue as? Double else { return nil }
        self = value
    }

    var storedValue: Any? { self }
}

extension String: PreferenceValue {
    init?(storedValue: Any) {
        guard let value = storedValue as? String else { return nil }
        self = value
    }

    var storedValue: Any? { self }
}

extension Optional: PreferenceValue where Wrapped: PreferenceValue {
    init?(storedValue: Any) {
        guard let value = Wrapped(storedValue: storedValue) else { return nil }
        self = .some(value)
    }

    var storedValue: Any? { self?.storedValue }
}

extension PreferenceValue where Self: RawRepresentable, RawValue: PreferenceValue {
    init?(storedValue: Any) {
        guard let raw = RawValue(storedValue: storedValue) else { return nil }
        self.init(rawValue: raw)
    }

    var storedValue: Any? { rawValue.storedValue }
}

extension CompletionLength: PreferenceValue {}
extension EscapeBehavior: PreferenceValue {}
extension SettingsPane: PreferenceValue {}
extension OnboardingStep: PreferenceValue {}

extension Set: PreferenceValue where Element: RawRepresentable, Element.RawValue == String {
    init?(storedValue: Any) {
        guard let raws = storedValue as? [String] else { return nil }
        self.init(raws.compactMap { Element(rawValue: $0) })
    }

    var storedValue: Any? { map(\.rawValue).sorted() }
}

extension Array: PreferenceValue where Element == String {
    init?(storedValue: Any) {
        guard let value = storedValue as? [String] else { return nil }
        self = value
    }

    var storedValue: Any? { self }
}

extension HotKey: PreferenceValue {
    init?(storedValue: Any) {
        guard let dict = storedValue as? [String: Int],
              let keyCode = dict["keyCode"].flatMap(UInt32.init(exactly:)),
              let modifiers = dict["modifiers"].flatMap(UInt32.init(exactly:))
        else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    var storedValue: Any? { ["keyCode": Int(keyCode), "modifiers": Int(modifiers)] }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
