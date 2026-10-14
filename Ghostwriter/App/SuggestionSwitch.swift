import GWCore


struct SuggestionSwitch {
    let preferences: Preferences
    let appState: AppState
    let appRules: AppRuleLibrary

    var isOnEverywhere: Bool { preferences.completionsEnabled && !appState.isGloballyPaused }

    func isOn(in bundleID: String) -> Bool {
        appState.appPauses[bundleID]?.isActive != true && appRules.effectiveRule(for: bundleID).completionsEnabled != false
    }

    func turnOnEverywhere() {
        appState.globalPause = nil
        preferences.completionsEnabled = true
    }

    func turnOffEverywhere(for duration: PauseDuration?) {
        if let duration {
            appState.globalPause = duration.pause
        } else {
            preferences.completionsEnabled = false
        }
    }

    func toggleEverywhere() {
        isOnEverywhere ? turnOffEverywhere(for: nil) : turnOnEverywhere()
    }

    func turnOn(in bundleID: String) {
        appState.resume(bundleID: bundleID)
        appRules.setCompletions(true, for: bundleID)
    }

    func turnOff(in bundleID: String, for duration: PauseDuration?) {
        if let duration {
            appState.pause(bundleID: bundleID, duration.pause)
        } else {
            appRules.setCompletions(false, for: bundleID)
        }
    }

    func toggle(in bundleID: String) {
        isOn(in: bundleID) ? turnOff(in: bundleID, for: .fifteenMinutes) : turnOn(in: bundleID)
    }
}
