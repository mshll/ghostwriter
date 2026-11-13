import Capture
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
    @ObservationIgnored private var prefilled: String?

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
        prefilled = instructions
    }

    func clearPrefilledInstructions() {
        guard let prefilled, preferences.customInstructions == prefilled else { return }
        preferences.customInstructions = ""
        self.prefilled = nil
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

    /// Stores the writing first, so a failed save leaves settings and instructions untouched.
    private func apply(_ data: CotypistData) async throws -> String {
        var texts = 0
        let recording = preferences.recordWriting && memory != nil
        if recording, let memory {
            let switchedOff = Set(data.rules.filter { $0.recordWriting == false }.map(\.bundleID))
            let sessions = data.sessions.filter { !switchedOff.contains($0.bundleID) && mayRecord($0) }
            texts = try await Self.store(sessions, in: memory)
        }
        let rules = appRules.importRules(data.rules)
        var instructions = false
        if let imported = data.instructions, preferences.customInstructions.isBlank {
            preferences.customInstructions = imported
            instructions = true
        }
        return Self.summary(texts: texts, rules: rules, instructions: instructions, skippedWriting: !recording && !data.sessions.isEmpty)
    }

    private func mayRecord(_ session: WritingSession) -> Bool {
        guard session.bundleID != Bundle.main.bundleIdentifier, !BuiltInAppRules.isTerminal(session.bundleID),
              !BuiltInAppRules.isCodeEditor(session.bundleID), appRules.isRecordingAllowed(for: session.bundleID)
        else { return false }
        guard let host = session.domain else { return true }
        return BuiltInAppRules.domainRule(forHost: host)?.recordWriting != false
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
