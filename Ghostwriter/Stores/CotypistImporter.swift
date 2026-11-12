import CotypistImport
import Foundation
import GWCore
import Memory
import Observation
import os

@Observable
final class CotypistImporter {
    enum Phase: Equatable {
        case idle, importing
        case finished(String)
        case failed(String)
    }

    private static let log = Logger.gw("CotypistImporter")

    private(set) var phase = Phase.idle
    let isAvailable: Bool

    @ObservationIgnored private let source: Cotypist
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let memory: MemoryStore?
    @ObservationIgnored private let appRules: AppRuleLibrary

    init(source: Cotypist = .local, preferences: Preferences, memory: MemoryStore?, appRules: AppRuleLibrary) {
        self.source = source
        self.preferences = preferences
        self.memory = memory
        self.appRules = appRules
        isAvailable = source.isInstalled
    }

    func prefillInstructions() {
        guard preferences.customInstructions.isBlank, let instructions = source.instructions() else { return }
        preferences.customInstructions = instructions
    }

    func run() {
        guard phase != .importing else { return }
        phase = .importing
        Task {
            do {
                let data = try await Self.load(source)
                phase = .finished(try await apply(data))
            } catch let error as CotypistError {
                Self.log.error("Importing from Cotypist failed: \(String(describing: error), privacy: .public)")
                phase = .failed(Self.message(for: error))
            } catch {
                Self.log.error("Saving the Cotypist import failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed("Saving the imported writing failed: \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ data: CotypistData) async throws -> String {
        let rules = appRules.importRules(data.rules)
        var instructions = false
        if let imported = data.instructions, preferences.customInstructions.isBlank {
            preferences.customInstructions = imported
            instructions = true
        }
        guard preferences.recordWriting, let memory else {
            return Self.summary(texts: 0, rules: rules, instructions: instructions, skippedWriting: !data.sessions.isEmpty)
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let sessions = data.sessions.filter { $0.bundleID != ownBundleID && appRules.isRecordingAllowed(for: $0.bundleID) }
        let texts = try await Self.store(sessions, in: memory)
        return Self.summary(texts: texts, rules: rules, instructions: instructions, skippedWriting: false)
    }

    @concurrent private static func load(_ source: Cotypist) async throws(CotypistError) -> CotypistData {
        try source.load()
    }

    @concurrent private static func store(_ sessions: [WritingSession], in memory: MemoryStore) async throws -> Int {
        try memory.importSessions(sessions)
    }

    private static func summary(texts: Int, rules: Int, instructions: Bool, skippedWriting: Bool) -> String {
        var parts: [String] = []
        if texts > 0 { parts.append(texts == 1 ? "1 text" : "\(texts.formatted()) texts") }
        if rules > 0 { parts.append(rules == 1 ? "1 app setting" : "\(rules) app settings") }
        if instructions { parts.append("your instructions") }
        let result = parts.isEmpty ? "Nothing new to import." : "Imported \(parts.formatted(.list(type: .and)))."
        return skippedWriting ? "\(result) Your writing was skipped because Learn from what you write is off." : result
    }

    private static func message(for error: CotypistError) -> String {
        switch error {
        case .notFound: "Cotypist\u{2019}s data wasn\u{2019}t found."
        case .accessDenied: "Access was denied. Import again and click Allow."
        case .keychain(let status): "The keychain refused access (\(status))."
        case .unreadable: "Cotypist\u{2019}s data couldn\u{2019}t be read."
        }
    }
}

extension String {
    fileprivate var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
