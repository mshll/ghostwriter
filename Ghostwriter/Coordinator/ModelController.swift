import Foundation
import GWCore
import Inference
import Prompting
import os

final class ModelController {
    nonisolated private static let log = Logger.gw("ModelController")

    private(set) var builder: PromptBuilder?

    private let services: AppServices
    private let appState: AppState
    private let preferences: Preferences
    private let power: PowerMonitor
    private var loadedID: String?
    private var loadTask: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var memoryIsCritical = false

    init(services: AppServices, appState: AppState, preferences: Preferences, power: PowerMonitor) {
        self.services = services
        self.appState = appState
        self.preferences = preferences
        self.power = power
    }

    func start() {
        services.models.onActiveModelChange = { [weak self] _ in self?.reconcile() }
        watchMemoryPressure()
        followBatteryPreference()
        followSuggestionSwitch()
        reconcile()
    }

    private var suggestionsOn: Bool {
        SuggestionSwitch(preferences: preferences, appState: appState, appRules: services.appRules).isOnEverywhere
    }

    private func followSuggestionSwitch() {
        withObservationTracking {
            _ = suggestionsOn
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reconcile()
                self?.followSuggestionSwitch()
            }
        }
    }

    private func followBatteryPreference() {
        withObservationTracking {
            _ = preferences.batterySmallerModel
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reconcile()
                self?.followBatteryPreference()
            }
        }
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.memoryIsCritical = source.data.contains(.critical)
                Self.log.info("Memory pressure \(self.memoryIsCritical ? "critical" : "normal", privacy: .public)")
                self.reconcile()
            }
        }
        source.resume()
        memoryPressure = source
    }

    func reconcile() {
        let choice = ModelChoice.choose(
            active: services.models.activeModel,
            installed: services.models.models.filter(services.models.isInstalled),
            suggestionsOn: suggestionsOn,
            memoryIsCritical: memoryIsCritical,
            prefersSmallest: power.isOnBattery && preferences.batterySmallerModel
        )
        switch choice {
        case .unloadWhileOff:
            appState.modelStatus = .unloadedWhileOff
        case .unloadForMemory:
            appState.modelStatus = .failed(message: "Unloaded while memory is low. It reloads when memory frees up.")
        case .load, .noModel:
            break
        }
        let wanted = choice.model
        guard wanted?.id != loadedID else { return }
        let previous = loadTask
        previous?.cancel()
        builder = nil
        loadedID = wanted?.id
        guard let wanted else {
            loadTask = Task { [engine = services.engine] in
                await previous?.value
                await engine.unload()
            }
            return
        }
        appState.modelStatus = .loading
        loadTask = Task { [weak self, engine = services.engine] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let info = try await engine.load(modelAt: wanted.localURL, config: EngineConfig())
                guard !Task.isCancelled, let self else { return }
                if let tokenizer = engine.tokenizer {
                    self.builder = PromptBuilder(counter: tokenizer)
                }
                self.appState.modelStatus = .ready(name: wanted.displayName)
                Self.log.info("Loaded \(info.name, privacy: .public)")
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.loadedID = nil
                self.appState.modelStatus = .failed(message: error.localizedDescription)
                Self.log.error("Loading \(wanted.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
