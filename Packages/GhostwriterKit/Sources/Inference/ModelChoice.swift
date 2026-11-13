public enum ModelChoice: Sendable, Equatable {
    case load(ModelSpec)
    case noModel
    case unloadWhileOff
    case unloadForMemory

    public var model: ModelSpec? {
        if case .load(let spec) = self { return spec }
        return nil
    }

    public static func choose(
        active: ModelSpec?, installed: [ModelSpec], suggestionsOn: Bool, memoryIsCritical: Bool, prefersSmallest: Bool
    ) -> ModelChoice {
        guard let active else { return .noModel }
        guard suggestionsOn else { return .unloadWhileOff }
        guard !memoryIsCritical else { return .unloadForMemory }
        guard prefersSmallest else { return .load(active) }
        return .load(installed.min { $0.sizeBytes < $1.sizeBytes } ?? active)
    }
}
