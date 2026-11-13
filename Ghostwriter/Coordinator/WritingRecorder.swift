import Foundation
import GWCore
import Memory
import Prompting
import os

final class WritingRecorder {
    nonisolated private static let log = Logger.gw("WritingRecorder")
    private static let saveInterval: TimeInterval = 30
    private static let languageSampleLength = 2_000
    private static let trackedFields = 20

    var isAllowed: (FieldSnapshot) -> Bool = { _ in false }

    private let memory: MemoryStore?
    private(set) var key = ""
    /// One session per field for the app's lifetime, so returning to a field continues its session
    /// instead of storing a near-copy that would come back as an example of itself.
    private var keys: [FieldID: String] = [:]
    private var writing: [FieldID: (state: FieldWriting, used: Date)] = [:]
    private var latest: FieldSnapshot?
    private var savedText = ""
    private var lastSave = Date.distantPast
    private var saving: Task<Void, Never>?

    init(memory: MemoryStore?) {
        self.memory = memory
    }

    func begin(_ snapshot: FieldSnapshot) {
        finish()
        key = keys[snapshot.id] ?? UUID().uuidString
        keys[snapshot.id] = key
        if writing[snapshot.id] == nil {
            writing[snapshot.id] = (FieldWriting(baseline: Self.text(of: snapshot)), .now)
            forgetOldestField()
        } else {
            writing[snapshot.id]?.state.refocused()
            writing[snapshot.id]?.used = .now
        }
        latest = snapshot
    }

    func update(_ snapshot: FieldSnapshot) {
        guard latest?.id == snapshot.id else { return }
        latest = snapshot
        if Date.now.timeIntervalSince(lastSave) > Self.saveInterval {
            save()
        }
    }

    func typed(_ count: Int) {
        guard let id = latest?.id else { return }
        writing[id]?.state.typed(count)
    }

    func inserted(_ text: String, into field: FieldID, after textBefore: String) {
        writing[field]?.state.inserted(text, after: textBefore)
    }

    func finish() {
        save()
        if let id = latest?.id, writing[id]?.state.hasTyped == false {
            writing[id] = nil
        }
        latest = nil
    }

    private func forgetOldestField() {
        guard writing.count > Self.trackedFields,
              let oldest = writing.min(by: { $0.value.used < $1.value.used })?.key else { return }
        writing[oldest] = nil
    }

    private func save() {
        lastSave = .now
        guard let memory, let snapshot = latest, isAllowed(snapshot), let state = writing[snapshot.id]?.state else { return }
        let text = Self.text(of: snapshot)
        guard text != savedText else { return }
        savedText = text
        let key = key
        let sampleLength = Self.languageSampleLength
        let previous = saving
        saving = Task.detached {
            await previous?.value
            guard let excerpt = state.excerpt(of: text) else { return }
            let session = WritingSession(
                key: key,
                bundleID: snapshot.app.bundleID,
                domain: snapshot.url?.host(),
                fieldLabel: snapshot.label,
                text: excerpt,
                language: LanguageDetector.dominantLanguage(of: String(excerpt.suffix(sampleLength)))
            )
            do {
                try memory.upsertSession(session)
            } catch {
                Self.log.error("Saving a writing session failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func text(of snapshot: FieldSnapshot) -> String {
        snapshot.textBefore + snapshot.selectedText + snapshot.textAfter
    }
}
