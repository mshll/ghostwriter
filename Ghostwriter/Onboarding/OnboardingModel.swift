import Inference
import Observation
import SwiftUI

enum OnboardingStep: String, CaseIterable {
    case welcome, access, model, personal, context, practice, done

    var ink: String {
        switch self {
        case .welcome: "Autocomplete"
        case .access: "First, let it see"
        case .model: "Runs on your Mac,"
        case .personal: "Make it"
        case .context: "Give it"
        case .practice: "Now you"
        case .done: "Press Tab."
        }
    }

    var ghost: String {
        switch self {
        case .welcome: "for your whole Mac."
        case .access: "where you type."
        case .model: "on its own GPU."
        case .personal: "sound like you."
        case .context: "more to go on."
        case .practice: "try it."
        case .done: "That\u{2019}s the interface."
        }
    }

    static func from(_ first: OnboardingStep) -> [OnboardingStep] {
        Array(allCases.drop { $0 != first })
    }

    var acceptsWithKeys: Bool { self == .welcome || self == .done }

    var dimsLetters: Bool { !acceptsWithKeys }
}

@Observable
final class OnboardingModel {
    private static let wordStagger: Duration = .milliseconds(75)

    let steps: [OnboardingStep]
    private(set) var step: OnboardingStep
    private(set) var acceptedWords = 0
    private(set) var pressedKey: String?
    private(set) var isLeaving = false
    private(set) var skipArmed = false
    var chosenModelID: String?
    var statusItemFrame: CGRect?

    @ObservationIgnored var onDropWord: (String) -> Void = { _ in }
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored var onBringToFront: () -> Void = {}
    @ObservationIgnored var onStepChange: (OnboardingStep) -> Void = { _ in }
    @ObservationIgnored var onGuide: (PermissionTopic) -> Void = { _ in }
    private(set) var guidedTopics: Set<PermissionTopic> = []

    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private let library: ModelLibrary
    @ObservationIgnored private var completion: Task<Void, Never>?

    init(steps: [OnboardingStep], appState: AppState, library: ModelLibrary) {
        self.steps = steps
        self.appState = appState
        self.library = library
        step = steps.first ?? .welcome
        chosenModelID = library.activeModel?.id ?? library.recommended?.id
    }

    var ghostWords: [String] { step.ghost.split(separator: " ").map(String.init) }
    var headlineComplete: Bool { acceptedWords >= ghostWords.count }

    func start() {
        onStepChange(step)
        if isSatisfied(step) { advance() }
    }

    func acceptWord(key: String? = nil) {
        if let key { flash(key) }
        guard !headlineComplete else { return }
        onDropWord(ghostWords[acceptedWords])
        withAnimation(.easeOut(duration: 0.36)) { acceptedWords += 1 }
    }

    func acceptAll(key: String? = nil) {
        if let key { flash(key) }
        completeHeadline(thenAdvance: false)
    }

    func completeHeadline(thenAdvance: Bool) {
        guard completion == nil else { return }
        let current = step
        completion = Task { [weak self] in
            while let self, !self.headlineComplete, self.step == current {
                self.acceptWord()
                do {
                    try await Task.sleep(for: Self.wordStagger)
                } catch {
                    return
                }
            }
            guard let self else { return }
            completion = nil
            guard thenAdvance, step == current else { return }
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            if step == current { advance() }
        }
    }

    func advance() {
        completion?.cancel()
        completion = nil
        var index = steps.firstIndex(of: step).map { $0 + 1 } ?? steps.endIndex
        while index < steps.endIndex, isSatisfied(steps[index]) { index += 1 }
        guard index < steps.endIndex else {
            finish()
            return
        }
        acceptedWords = 0
        withAnimation(.easeIn(duration: 0.18)) { step = steps[index] }
        onStepChange(step)
    }

    func escape() {
        guard !skipArmed else {
            finish()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { skipArmed = true }
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.2)) { self?.skipArmed = false }
        }
    }

    func finish() {
        guard !isLeaving else { return }
        completion?.cancel()
        isLeaving = true
        onFinish()
    }

    func accessibilityChanged() {
        guard step == .access, appState.accessibilityGranted else { return }
        onBringToFront()
        completeHeadline(thenAdvance: true)
    }

    func guide(_ topic: PermissionTopic) {
        guidedTopics.insert(topic)
        onGuide(topic)
    }

    func primaryAction() {
        switch step {
        case .access:
            if appState.accessibilityGranted {
                advance()
            } else {
                guide(.accessibility)
            }
        case .model:
            let chosen = library.models.first { $0.id == chosenModelID }
            if let chosen, library.activeModel?.id == chosen.id || library.downloadProgress[chosen.id] != nil {
                completeHeadline(thenAdvance: true)
            } else {
                downloadChosenModel()
            }
        case .personal, .context:
            completeHeadline(thenAdvance: true)
        case .welcome, .practice, .done:
            break
        }
    }

    func downloadChosenModel() {
        guard let spec = library.models.first(where: { $0.id == chosenModelID }) else { return }
        if library.isInstalled(spec) {
            library.select(spec)
        } else {
            library.download(spec)
        }
        completeHeadline(thenAdvance: true)
    }

    private func isSatisfied(_ step: OnboardingStep) -> Bool {
        step == .access && appState.accessibilityGranted && steps.count > 1
    }

    private func flash(_ key: String) {
        pressedKey = key
        Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            if self?.pressedKey == key { self?.pressedKey = nil }
        }
    }
}
