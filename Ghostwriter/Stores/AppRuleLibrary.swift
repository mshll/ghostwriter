import Capture
import Foundation
import GWCore
import Memory
import Observation
import os

@Observable
final class AppRuleLibrary {
    private static let log = Logger.gw("AppRuleLibrary")

    private(set) var rules: [AppRule] = []
    private(set) var lastError: String?

    @ObservationIgnored private let store: MemoryStore?
    @ObservationIgnored private var rulesByBundleID: [String: AppRule] = [:]

    init(store: MemoryStore?) {
        self.store = store
        reload()
    }

    func rule(for bundleID: String) -> AppRule? { rulesByBundleID[bundleID] }

    func effectiveRule(for bundleID: String) -> AppRule {
        (BuiltInAppRules.rule(for: bundleID) ?? AppRule(bundleID: bundleID)).merged(with: rulesByBundleID[bundleID])
    }

    func isRecordingAllowed(for bundleID: String) -> Bool {
        effectiveRule(for: bundleID).recordWriting ?? true
    }

    func reload() {
        guard let store else { return }
        do {
            apply(try store.appRules())
        } catch {
            report(error, "Loading app rules failed")
        }
    }

    func save(_ rule: AppRule) {
        guard let store else { return }
        do {
            try store.save(rule)
            var updated = rules.filter { $0.bundleID != rule.bundleID }
            updated.append(rule)
            apply(updated)
        } catch {
            report(error, "Saving the rule for \(rule.bundleID) failed")
        }
    }

    func delete(bundleID: String) {
        guard let store else { return }
        do {
            try store.deleteRule(bundleID: bundleID)
            apply(rules.filter { $0.bundleID != bundleID })
        } catch {
            report(error, "Removing the rule for \(bundleID) failed")
        }
    }

    func setCompletions(_ enabled: Bool, for bundleID: String) {
        update(bundleID, \.completionsEnabled, to: enabled)
    }

    func setTabAccept(_ enabled: Bool, for bundleID: String) {
        update(bundleID, \.tabAcceptEnabled, to: enabled)
    }

    func setRecordWriting(_ enabled: Bool, for bundleID: String) {
        update(bundleID, \.recordWriting, to: enabled)
    }

    private func update(_ bundleID: String, _ field: WritableKeyPath<AppRule, Bool?>, to enabled: Bool) {
        var rule = rulesByBundleID[bundleID] ?? AppRule(bundleID: bundleID)
        let fallback = BuiltInAppRules.rule(for: bundleID)?[keyPath: field] ?? true
        rule[keyPath: field] = enabled == fallback ? nil : enabled
        if rule == AppRule(bundleID: bundleID) {
            if rulesByBundleID[bundleID] != nil { delete(bundleID: bundleID) }
        } else {
            save(rule)
        }
    }

    private func apply(_ newRules: [AppRule]) {
        rules = newRules.sorted { AppInfo.name(for: $0.bundleID).localizedStandardCompare(AppInfo.name(for: $1.bundleID)) == .orderedAscending }
        rulesByBundleID = Dictionary(newRules.map { ($0.bundleID, $0) }, uniquingKeysWith: { _, last in last })
        lastError = nil
    }

    private func report(_ error: any Error, _ message: String) {
        Self.log.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
        lastError = "\(message): \(error.localizedDescription)"
    }
}
