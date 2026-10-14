import Foundation
import GWCore
import Memory
import Prompting
import os

final class WritingRecorder {
    nonisolated private static let log = Logger.gw("WritingRecorder")
    private static let saveInterval: TimeInterval = 30
    private static let minimumCharacters = 100

    var isAllowed: (FieldSnapshot) -> Bool = { _ in false }

    private let memory: MemoryStore?
    private(set) var key = ""
    /// One session per field for the app's lifetime, so returning to a field continues its session
    /// instead of storing a near-copy that would come back as an example of itself.
    private var keys: [FieldID: String] = [:]
    private var latest: FieldSnapshot?
    private var savedText = ""
    private var lastSave = Date.distantPast

    init(memory: MemoryStore?) {
        self.memory = memory
    }

    func begin(_ snapshot: FieldSnapshot) {
        finish()
        key = keys[snapshot.id] ?? UUID().uuidString
        keys[snapshot.id] = key
        latest = snapshot
    }

    func update(_ snapshot: FieldSnapshot) {
        guard latest?.id == snapshot.id else { return }
        latest = snapshot
        if Date.now.timeIntervalSince(lastSave) > Self.saveInterval {
            save()
        }
    }

    func finish() {
        save()
        latest = nil
    }

    private func save() {
        lastSave = .now
        guard let memory, let snapshot = latest, isAllowed(snapshot) else { return }
        let text = snapshot.textBefore + snapshot.selectedText + snapshot.textAfter
        guard text.count >= Self.minimumCharacters, text != savedText else { return }
        savedText = text
        let session = WritingSession(
            key: key,
            bundleID: snapshot.app.bundleID,
            domain: snapshot.url?.host(),
            fieldLabel: snapshot.label,
            text: text,
            language: LanguageDetector.dominantLanguage(of: text)
        )
        Task.detached {
            do {
                try memory.upsertSession(session)
            } catch {
                Self.log.error("Saving a writing session failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
