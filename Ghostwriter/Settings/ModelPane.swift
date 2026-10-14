import Inference
import IOKit.ps
import SwiftUI

struct ModelPane: View {
    @Environment(ModelLibrary.self) private var library
    @Environment(AppState.self) private var appState
    @State private var pendingDeletion: ModelSpec?
    @State private var isConfirmingDeletion = false
    @State private var deletionError: String?
    @State private var isShowingDeletionError = false

    var body: some View {
        SettingsPaneView(pane: .model) {
            Section {
                ModelInUseRow(model: library.activeModel, status: appState.modelStatus)
            }

            Section {
                if library.models.isEmpty {
                    Text("No models are available yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.models) { spec in
                    ModelRow(spec: spec) {
                        pendingDeletion = spec
                        isConfirmingDeletion = true
                    }
                }
            } header: {
                Text("Models")
                    .settingsSearchTarget(ModelSetting.models)
            } footer: {
                HardwareSummary(hardware: library.hardware)
            }

            Section {
                SettingRow(ModelSetting.ownModels) {
                    HStack {
                        Button("Show Folder", action: library.revealModelsFolder)
                        Button("Refresh", action: library.refresh)
                    }
                }
            }

            BatterySection()
        }
        .onAppear(perform: library.refresh)
        .confirmationDialog(
            "Delete \(pendingDeletion?.displayName ?? "this model")?",
            isPresented: $isConfirmingDeletion,
            presenting: pendingDeletion
        ) { spec in
            Button("Delete", role: .destructive) { delete(spec) }
        } message: { spec in
            Text("This frees \(spec.sizeBytes.formatted(.byteCount(style: .file))). You can download it again later.")
        }
        .alert("Couldn\u{2019}t delete the model", isPresented: $isShowingDeletionError) {
            Button("OK") {}
        } message: {
            Text(deletionError ?? "")
        }
    }

    private func delete(_ spec: ModelSpec) {
        do {
            try library.delete(spec)
        } catch {
            deletionError = error.localizedDescription
            isShowingDeletionError = true
        }
    }
}

private struct ModelRow: View {
    @Environment(ModelLibrary.self) private var library
    let spec: ModelSpec
    let requestDeletion: () -> Void

    var body: some View {
        let installed = library.isInstalled(spec)
        let isActive = library.activeModel?.id == spec.id
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                library.select(spec)
            } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!installed)
            .help(installed ? "Use this model" : "Download the model first")
            .accessibilityLabel(isActive ? "\(spec.displayName), in use" : "Use \(spec.displayName)")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spec.displayName).fontWeight(.medium)
                    if library.isRecommended(spec) {
                        Text("Recommended for your Mac")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .rect(cornerRadius: 4))
                            .foregroundStyle(.tint)
                    }
                }
                if !spec.summary.isEmpty {
                    Text(spec.summary)
                        .font(.callout)
                }
                Text(details(installed: installed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if library.mayExceedMemory(spec) {
                    Label("May not fit in this Mac\u{2019}s \(library.hardware.memoryGB) GB of memory alongside your apps.", systemImage: "memorychip")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = library.downloadErrors[spec.id] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            ModelRowAction(spec: spec, installed: installed, requestDeletion: requestDeletion)
        }
        .padding(.vertical, 2)
    }

    private func details(installed: Bool) -> String {
        var parts = [spec.sizeBytes.formatted(.byteCount(style: .file))]
        if spec.minMemoryGB > 0 { parts.append("needs \(spec.minMemoryGB) GB memory") }
        if spec.family == .custom { parts.append("custom") }
        if installed { parts.append("downloaded") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct ModelRowAction: View {
    @Environment(ModelLibrary.self) private var library
    let spec: ModelSpec
    let installed: Bool
    let requestDeletion: () -> Void

    var body: some View {
        if let progress = library.downloadProgress[spec.id] {
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(width: 90)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel Download", systemImage: "xmark.circle.fill") { library.cancelDownload(spec) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        } else if installed {
            Button("Delete", systemImage: "trash", role: .destructive, action: requestDeletion)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete this model")
        } else {
            Button("Download") { library.download(spec) }
        }
    }
}

private struct HardwareSummary: View {
    let hardware: HardwareProfile

    var body: some View {
        Text("This Mac: \(hardware.chip.isEmpty ? "Apple silicon" : hardware.chip), \(hardware.memoryGB) GB memory.")
    }
}

private struct ModelInUseRow: View {
    let model: ModelSpec?
    let status: ModelStatus

    var body: some View {
        LabeledContent {
            switch status {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .downloading(let progress):
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .notInstalled:
                EmptyView()
            }
        } label: {
            Text(model?.displayName ?? "No model in use")
            Text(detail)
        }
        .settingsSearchTarget(ModelSetting.modelInUse)
    }

    private var detail: String {
        switch status {
        case .notInstalled: "Download a model below to start getting suggestions."
        case .downloading: "Downloading the model\u{2026}"
        case .loading: "Loading the model\u{2026}"
        case .ready: model.map { $0.summary.isEmpty ? "Writing your suggestions." : $0.summary } ?? "Writing your suggestions."
        case .failed(let message): "The model failed to load: \(message)"
        }
    }
}

private struct BatterySection: View {
    @Environment(Preferences.self) private var preferences
    @State private var onBattery = PowerSource.isOnBattery

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            SettingRow(ModelSetting.onDemand, isOn: $preferences.batteryOnDemandOnly)
            SettingRow(ModelSetting.shorterOnBattery, isOn: $preferences.batteryShorterCompletions)
            SettingRow(ModelSetting.smallerModel, isOn: $preferences.batterySmallerModel)
        } header: {
            Text("On battery power")
        } footer: {
            Text(onBattery
                 ? "This Mac is on battery now, so these settings are active."
                 : "This Mac is plugged in. These settings apply when it runs on battery.")
        }
        .onAppear { onBattery = PowerSource.isOnBattery }
    }
}

private enum PowerSource {
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

enum ModelSetting: SettingKey {
    case modelInUse, models, ownModels, onDemand, shorterOnBattery, smallerModel

    var text: SettingText {
        switch self {
        case .modelInUse: SettingText("Model in use", keywords: ["status", "loading", "ready", "failed"])
        case .models: SettingText("Models", keywords: ["download", "gemma", "gguf", "delete"])
        case .ownModels: SettingText("Your own models", subtitle: "Drop a base (pretrained, not instruct or chat) .gguf file into the Models folder, then refresh. Ghostwriter continues text, so base models work best.", keywords: ["gguf", "custom", "folder"])
        case .onDemand: SettingText("Only suggest when asked", subtitle: "Suggestions appear only when you press the Suggest Now shortcut.", keywords: ["battery", "power", "on demand"])
        case .shorterOnBattery: SettingText("Shorter suggestions on battery", subtitle: "Short suggestions finish sooner and use less power.", keywords: ["battery", "power"])
        case .smallerModel: SettingText("Use a smaller model", subtitle: "Switches to the smallest downloaded model. Faster and lighter, with somewhat weaker suggestions.", keywords: ["battery", "power"])
        }
    }
}
