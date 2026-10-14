import AppKit
import GWCore
import Inference
import Observation
import os

@Observable
final class ModelLibrary {
    private static let log = Logger.gw("ModelLibrary")
    private static let memoryHeadroomBytes: Int64 = 4 << 30

    let hardware = HardwareProfile.current
    let recommended: ModelSpec?

    private(set) var models: [ModelSpec] = []
    private(set) var installedIDs: Set<String> = []
    private(set) var downloadProgress: [String: Double] = [:]
    private(set) var downloadErrors: [String: String] = [:]
    private(set) var activeModel: ModelSpec?

    @ObservationIgnored var onActiveModelChange: ((ModelSpec?) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private let downloader: ModelDownloader
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(preferences: Preferences, appState: AppState, downloader: ModelDownloader) {
        self.preferences = preferences
        self.appState = appState
        self.downloader = downloader
        recommended = ModelCatalog.recommended(for: hardware)
        refresh()
    }

    var downloadingModels: [ModelSpec] {
        models.filter { downloadProgress[$0.id] != nil }
    }

    func isInstalled(_ spec: ModelSpec) -> Bool { installedIDs.contains(spec.id) }

    func isRecommended(_ spec: ModelSpec) -> Bool { spec.id == recommended?.id }

    func mayExceedMemory(_ spec: ModelSpec) -> Bool {
        spec.sizeBytes + Self.memoryHeadroomBytes > Int64(hardware.memoryGB) << 30
    }

    func refresh() {
        let installed = ModelCatalog.installed()
        let curatedIDs = Set(ModelCatalog.curated.map(\.id))
        models = ModelCatalog.curated + installed.filter { !curatedIDs.contains($0.id) }
        installedIDs = Set(installed.map(\.id))
        updateActiveModel()
    }

    func select(_ spec: ModelSpec) {
        preferences.selectedModelID = spec.id
        updateActiveModel()
    }

    func download(_ spec: ModelSpec) {
        guard downloadTasks[spec.id] == nil else { return }
        downloadProgress[spec.id] = 0
        downloadErrors[spec.id] = nil
        updateStatus()
        downloadTasks[spec.id] = Task { [downloader] in
            do {
                _ = try await downloader.download(spec) { fraction in
                    Task { @MainActor in self.reportProgress(fraction, for: spec.id) }
                }
                finishDownload(spec)
            } catch {
                if !(error is CancellationError || Task.isCancelled) {
                    Self.log.error("Download of \(spec.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    downloadErrors[spec.id] = error.localizedDescription
                }
                endDownload(spec.id)
            }
        }
    }

    func cancelDownload(_ spec: ModelSpec) {
        downloadTasks[spec.id]?.cancel()
        endDownload(spec.id)
        Task { [downloader] in await downloader.cancel(spec) }
    }

    func delete(_ spec: ModelSpec) throws {
        try FileManager.default.removeItem(at: spec.localURL)
        if preferences.selectedModelID == spec.id {
            preferences.selectedModelID = nil
        }
        refresh()
    }

    func revealModelsFolder() {
        do {
            try FileManager.default.createDirectory(at: AppPaths.models, withIntermediateDirectories: true)
        } catch {
            Self.log.error("Creating the models folder failed: \(error.localizedDescription, privacy: .public)")
        }
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.models])
    }

    private func reportProgress(_ fraction: Double, for id: String) {
        guard let current = downloadProgress[id], fraction - current >= 0.002 || fraction >= 1 else { return }
        downloadProgress[id] = min(fraction, 1)
        updateStatus()
    }

    private func finishDownload(_ spec: ModelSpec) {
        endDownload(spec.id)
        if activeModel == nil {
            preferences.selectedModelID = spec.id
        }
        refresh()
    }

    private func endDownload(_ id: String) {
        downloadTasks[id] = nil
        downloadProgress[id] = nil
        updateStatus()
    }

    private func updateActiveModel() {
        let installed = models.filter(isInstalled)
        let selected: ModelSpec? = if let id = preferences.selectedModelID {
            installed.first { $0.id == id }
        } else {
            installed.first { isRecommended($0) } ?? installed.first
        }
        guard selected != activeModel else {
            updateStatus()
            return
        }
        activeModel = selected
        updateStatus()
        onActiveModelChange?(selected)
    }

    private func updateStatus() {
        guard activeModel == nil else { return }
        if let progress = downloadProgress.values.max() {
            appState.modelStatus = .downloading(progress: progress)
        } else {
            appState.modelStatus = .notInstalled
        }
    }
}
