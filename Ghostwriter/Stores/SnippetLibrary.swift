import Foundation
import GWCore
import Memory
import Observation
import os

@Observable
final class SnippetLibrary {
    private static let log = Logger.gw("SnippetLibrary")

    private(set) var snippets: [Snippet] = []
    private(set) var lastError: String?

    @ObservationIgnored private let store: MemoryStore?

    init(store: MemoryStore?) {
        self.store = store
        reload()
    }

    var enabledSnippets: [Snippet] { snippets.filter(\.isEnabled) }

    func reload() {
        guard let store else { return }
        do {
            snippets = try store.snippets().sorted { $0.trigger < $1.trigger }
            lastError = nil
        } catch {
            report(error, "Loading snippets failed")
        }
    }

    func validationError(for snippet: Snippet) -> String? {
        let trigger = snippet.trigger
        if trigger.isEmpty { return "Enter a trigger." }
        if trigger.contains(where: \.isWhitespace) { return "Triggers can't contain spaces." }
        if snippets.contains(where: { $0.trigger == trigger && $0.id != snippet.id }) {
            return "Another snippet already uses \u{201C}\(trigger)\u{201D}."
        }
        if snippet.body.isEmpty { return "Enter the text to insert." }
        return nil
    }

    func save(_ snippet: Snippet) {
        guard let store, validationError(for: snippet) == nil else { return }
        do {
            try store.save(snippet)
            snippets = (snippets.filter { $0.id != snippet.id } + [snippet]).sorted { $0.trigger < $1.trigger }
            lastError = nil
        } catch {
            report(error, "Saving the snippet failed")
        }
    }

    func delete(id: UUID) {
        guard let store else { return }
        do {
            try store.deleteSnippet(id: id)
            snippets.removeAll { $0.id == id }
            lastError = nil
        } catch {
            report(error, "Deleting the snippet failed")
        }
    }

    private func report(_ error: any Error, _ message: String) {
        Self.log.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
        lastError = "\(message): \(error.localizedDescription)"
    }
}
