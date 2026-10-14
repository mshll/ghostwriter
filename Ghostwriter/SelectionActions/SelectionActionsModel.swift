import Actions
import Foundation
import Observation

@Observable
final class SelectionActionsModel {
    enum Phase: Equatable {
        case choosing
        case running(WritingAction, text: String)
        case finished(WritingAction, text: String)
        case synonyms(loading: Bool, items: [String])
        case failed(String)
    }

    private enum Request {
        case action(WritingAction)
        case synonyms
    }

    let selectedText: String
    let actions: [WritingAction]
    let unavailableReason: String?
    var targetLanguage: String {
        didSet { onTargetLanguageChange(targetLanguage) }
    }
    var selectedSynonym: String?
    private(set) var phase: Phase = .choosing

    @ObservationIgnored private let surroundingText: String
    @ObservationIgnored private let assistant: WritingAssistant
    @ObservationIgnored private let onTargetLanguageChange: (String) -> Void
    @ObservationIgnored private var lastRequest: Request?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        selectedText: String, surroundingText: String, actions: [WritingAction], targetLanguage: String,
        assistant: WritingAssistant, onTargetLanguageChange: @escaping (String) -> Void
    ) {
        self.selectedText = selectedText
        self.surroundingText = surroundingText
        self.actions = actions
        self.targetLanguage = targetLanguage
        self.assistant = assistant
        self.onTargetLanguageChange = onTargetLanguageChange
        unavailableReason = WritingAssistant.isAvailable ? nil : (WritingAssistant.unavailableReason ?? "Apple Intelligence is unavailable.")
    }

    var offersSynonyms: Bool {
        let words = selectedText.split(whereSeparator: \.isWhitespace)
        return (1...3).contains(words.count) && !selectedText.contains(where: \.isNewline)
    }

    var replacement: String? {
        switch phase {
        case .finished(_, let text): text
        case .synonyms: selectedSynonym
        case .choosing, .running, .failed: nil
        }
    }

    var failedAction: WritingAction? {
        guard case .failed = phase, case .action(let action) = lastRequest else { return nil }
        return action
    }

    var canRetry: Bool {
        switch phase {
        case .finished, .failed: lastRequest != nil
        case .synonyms(let loading, _): !loading
        case .choosing, .running: false
        }
    }

    func run(_ action: WritingAction) {
        guard unavailableReason == nil else { return }
        lastRequest = .action(action)
        phase = .running(action, text: "")
        let text = selectedText
        let language = action == .translate ? targetLanguage : nil
        start { [assistant] model in
            var latest = ""
            for try await partial in assistant.run(action, on: text, targetLanguage: language) {
                latest = partial
                model.phase = .running(action, text: partial)
            }
            model.phase = .finished(action, text: latest)
        }
    }

    func loadSynonyms() {
        guard unavailableReason == nil, offersSynonyms else { return }
        lastRequest = .synonyms
        selectedSynonym = nil
        phase = .synonyms(loading: true, items: [])
        let phrase = selectedText
        let context = surroundingText
        start { [assistant] model in
            let items = try await assistant.synonyms(for: phrase, in: context)
            model.selectedSynonym = items.first
            model.phase = .synonyms(loading: false, items: items)
        }
    }

    func retry() {
        switch lastRequest {
        case .action(let action): run(action)
        case .synonyms: loadSynonyms()
        case nil: break
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func start(_ work: @escaping @MainActor (SelectionActionsModel) async throws -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
