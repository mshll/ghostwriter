import Foundation
import GWCore
import Memory
import Prompting
import os

final class WritingRecorder {
    private struct Field {
        var state: FieldWriting
        var used: Date
        let bundleID: String
    }

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
    private var writing: [FieldID: Field] = [:]
    private var latest: FieldSnapshot?
    private var saved: (text: String, sends: Int)?
    private var lastSave = Date.distantPast
    private var saving: Task<Void, Never>?
    private var erasures: Int

    init(memory: MemoryStore?) {
        self.memory = memory
        erasures = memory?.erasureCount ?? 0
    }

    func begin(_ snapshot: FieldSnapshot) {
        finish()
        key = keys[snapshot.id] ?? UUID().uuidString
        keys[snapshot.id] = key
        if writing[snapshot.id] == nil {
            writing[snapshot.id] = Field(state: FieldWriting(baseline: Self.text(of: snapshot)), used: .now, bundleID: snapshot.app.bundleID)
            forgetOldestField()
        } else {
            writing[snapshot.id]?.state.refocused()
            writing[snapshot.id]?.used = .now
        }
        latest = snapshot
    }

    func update(_ snapshot: FieldSnapshot) {
        guard let previous = latest, previous.id == snapshot.id else { return }
        forgetErasedWriting()
        latest = snapshot
        if Self.isBlank(snapshot), !Self.isBlank(previous) {
            writing[snapshot.id]?.state.emptied(
                from: Self.text(of: previous), to: Self.text(of: snapshot), keepsMessage: isAllowed(previous)
            )
        }
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

    /// Forgets fields whose writing was erased. The current field starts again from its text at that point,
    /// so only what is written after the erase is saved.
    private func forgetErasedWriting() {
        guard let memory else { return }
        let count = memory.erasureCount
        guard count != erasures else { return }
        for (id, field) in writing where memory.wasErased(field.bundleID, since: erasures) {
            writing[id] = nil
            keys[id] = nil
        }
        erasures = count
        guard let latest, writing[latest.id] == nil else { return }
        key = UUID().uuidString
        keys[latest.id] = key
        writing[latest.id] = Field(state: FieldWriting(baseline: Self.text(of: latest)), used: .now, bundleID: latest.app.bundleID)
        saved = nil
    }

    private func forgetOldestField() {
        guard writing.count > Self.trackedFields,
              let oldest = writing.min(by: { $0.value.used < $1.value.used })?.key else { return }
        writing[oldest] = nil
    }

    private func save() {
        lastSave = .now
        forgetErasedWriting()
        guard let memory, let snapshot = latest, isAllowed(snapshot), let state = writing[snapshot.id]?.state else { return }
        let text = Self.text(of: snapshot)
        guard saved?.text != text || saved?.sends != state.sends else { return }
        saved = (text, state.sends)
        let key = key
        let erasures = erasures
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
                try memory.upsertSession(session, unlessErasedSince: erasures)
            } catch {
                Self.log.error("Saving a writing session failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func isBlank(_ snapshot: FieldSnapshot) -> Bool {
        FieldWriting.isBlank(snapshot.textBefore) && FieldWriting.isBlank(snapshot.selectedText)
            && FieldWriting.isBlank(snapshot.textAfter)
    }

    private static func text(of snapshot: FieldSnapshot) -> String {
        snapshot.textBefore + snapshot.selectedText + snapshot.textAfter
    }
}
