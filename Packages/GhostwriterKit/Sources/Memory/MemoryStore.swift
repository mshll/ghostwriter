import Foundation
import GRDB
import GWCore
import os
import Synchronization

public final class MemoryStore: Sendable {
    struct Retention: Sendable {
        var maxAge: TimeInterval = 90 * 24 * 3_600
        var maxSessions = 5_000
        var maxEventAge: TimeInterval = 400 * 24 * 3_600
        var interval: TimeInterval = 3_600
    }

    struct State {
        var lastPurge = Date.distantPast
        var writingGeneration = 0
        var followers: [FollowersKey: [String: [String: Double]]] = [:]

        mutating func writingChanged() {
            writingGeneration += 1
            followers = [:]
        }
    }

    static let log = Logger.gw("memory")

    let writer: any DatabaseWriter
    let retention: Retention
    let calendar: Calendar
    let state = Mutex(State())

    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(writer: DatabasePool(path: url.path(percentEncoded: false), configuration: Self.configuration))
    }

    init(
        writer: any DatabaseWriter, retention: Retention = Retention(), calendar: Calendar = .autoupdatingCurrent,
        now: Date = .now
    ) throws {
        self.writer = writer
        self.retention = retention
        self.calendar = calendar
        try Schema.migrator.migrate(writer)
        try purge(now: now)
    }

    public static func inMemory() throws -> MemoryStore {
        try inMemory(retention: Retention())
    }

    static func inMemory(retention: Retention, calendar: Calendar = .autoupdatingCurrent) throws -> MemoryStore {
        try MemoryStore(writer: DatabaseQueue(configuration: configuration), retention: retention, calendar: calendar)
    }

    /// Deleted rows are overwritten with zeros, so erased writing does not linger in free pages.
    static var configuration: Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        return configuration
    }

    public func upsertSession(_ session: WritingSession) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO writing_sessions
                        (key, bundleID, domain, fieldLabel, text, bigrams, language, updatedAt, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        bundleID = excluded.bundleID, domain = excluded.domain, fieldLabel = excluded.fieldLabel,
                        text = excluded.text, bigrams = excluded.bigrams, language = excluded.language,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [
                    session.key, session.bundleID, session.domain, session.fieldLabel, session.text,
                    Words.indexedBigrams(in: session.text), session.language, session.updatedAt, session.updatedAt,
                ]
            )
        }
        let now = Date.now
        let purgeDue = state.withLock { state in
            state.writingChanged()
            return now.timeIntervalSince(state.lastPurge) >= retention.interval
        }
        if purgeDue { try purge(now: now) }
    }

    /// Deletes the writing, then rebuilds the full-text index, compacts the file and empties the
    /// write-ahead log, so no erased words remain in the database files.
    public func eraseWriting(bundleID: String?) throws {
        let removed = try writer.write { db in
            if let bundleID {
                try db.execute(sql: "DELETE FROM writing_sessions WHERE bundleID = ?", arguments: [bundleID])
            } else {
                try db.execute(sql: "DELETE FROM writing_sessions")
            }
            let removed = db.changesCount
            try db.execute(sql: "INSERT INTO writing_sessions_ft(writing_sessions_ft) VALUES('rebuild')")
            return removed
        }
        state.withLock { $0.writingChanged() }
        try writer.vacuum()
        try writer.barrierWriteWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
        }
        Self.log.info("Erased \(removed) writing sessions")
    }

    public func writingCount(bundleID: String?) throws -> Int {
        try writer.read { db in
            if let bundleID {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM writing_sessions WHERE bundleID = ?", arguments: [bundleID]) ?? 0
            } else {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM writing_sessions") ?? 0
            }
        }
    }

    func purge(now: Date) throws {
        let removed = try writer.write { db in
            try db.execute(
                sql: "DELETE FROM acceptance_events WHERE date < ?",
                arguments: [now.addingTimeInterval(-retention.maxEventAge)]
            )
            try db.execute(
                sql: "DELETE FROM suggestion_counts WHERE day < ?",
                arguments: [dayKey(now.addingTimeInterval(-retention.maxEventAge))]
            )
            try db.execute(
                sql: "DELETE FROM writing_sessions WHERE updatedAt < ?",
                arguments: [now.addingTimeInterval(-retention.maxAge)]
            )
            var removed = db.changesCount
            try db.execute(
                sql: """
                    DELETE FROM writing_sessions WHERE id IN (
                        SELECT id FROM writing_sessions ORDER BY updatedAt DESC, id DESC LIMIT -1 OFFSET ?
                    )
                    """,
                arguments: [retention.maxSessions]
            )
            removed += db.changesCount
            return removed
        }
        state.withLock { state in
            state.lastPurge = now
            if removed > 0 { state.writingChanged() }
        }
        if removed > 0 { Self.log.info("Purged \(removed) writing sessions") }
    }

    public func recordAcceptance(_ event: AcceptanceEvent) throws {
        let day = dayKey(event.date)
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO acceptance_events (kind, bundleID, words, characters, date, day) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [event.kind.rawValue, event.bundleID, event.words, event.characters, event.date, day]
            )
        }
    }

    public func recordSuggestion(_ outcome: SuggestionOutcome, bundleID: String, date: Date = .now) throws {
        let column = switch outcome {
        case .shown: "shown"
        case .used: "used"
        }
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO suggestion_counts (day, bundleID, \(column)) VALUES (?, ?, 1)
                    ON CONFLICT (day, bundleID) DO UPDATE SET \(column) = \(column) + 1
                    """,
                arguments: [dayKey(date), bundleID]
            )
        }
    }

    public func appStats(days: Int) throws -> [AppStat] {
        try appStats(days: days, now: .now)
    }

    func appStats(days: Int, now: Date) throws -> [AppStat] {
        guard let first = firstDayKey(days: days, now: now) else { return [] }
        let (accepted, counted) = try writer.read { db in
            (
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT bundleID, SUM(words) AS words, COUNT(*) AS acceptances
                        FROM acceptance_events WHERE day >= ? GROUP BY bundleID
                        """,
                    arguments: [first]
                ),
                try Row.fetchAll(
                    db,
                    sql: "SELECT bundleID, SUM(shown) AS shown, SUM(used) AS used FROM suggestion_counts WHERE day >= ? GROUP BY bundleID",
                    arguments: [first]
                )
            )
        }
        var stats: [String: AppStat] = [:]
        func stat(_ bundleID: String) -> AppStat {
            stats[bundleID] ?? AppStat(bundleID: bundleID, wordsAccepted: 0, acceptances: 0, suggestionsShown: 0, suggestionsUsed: 0)
        }
        for row in accepted {
            var entry = stat(row["bundleID"])
            entry.wordsAccepted = row["words"]
            entry.acceptances = row["acceptances"]
            stats[entry.bundleID] = entry
        }
        for row in counted {
            var entry = stat(row["bundleID"])
            entry.suggestionsShown = row["shown"]
            entry.suggestionsUsed = row["used"]
            stats[entry.bundleID] = entry
        }
        return stats.values.sorted {
            ($1.wordsAccepted, $1.suggestionsShown, $0.bundleID) < ($0.wordsAccepted, $0.suggestionsShown, $1.bundleID)
        }
    }

    public func kindStats(days: Int) throws -> [KindStat] {
        try kindStats(days: days, now: .now)
    }

    func kindStats(days: Int, now: Date) throws -> [KindStat] {
        guard let first = firstDayKey(days: days, now: now) else { return [] }
        let rows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT kind, SUM(words) AS words, COUNT(*) AS acceptances
                    FROM acceptance_events WHERE day >= ? GROUP BY kind
                    """,
                arguments: [first]
            )
        }
        return rows
            .compactMap { row in
                AcceptanceEvent.Kind(rawValue: row["kind"]).map {
                    KindStat(kind: $0, wordsAccepted: row["words"], acceptances: row["acceptances"])
                }
            }
            .sorted { ($1.wordsAccepted, $1.acceptances) < ($0.wordsAccepted, $0.acceptances) }
    }

    private func firstDayKey(days: Int, now: Date) -> String? {
        guard days > 0,
              let first = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))
        else { return nil }
        return dayKey(first)
    }

    public func dailyStats(days: Int) throws -> [DailyStat] {
        try dailyStats(days: days, now: .now)
    }

    func dailyStats(days: Int, now: Date) throws -> [DailyStat] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        let dates = (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard let first = dates.first else { return [] }
        let rows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT day, SUM(words) AS words, SUM(characters) AS characters, COUNT(*) AS acceptances
                    FROM acceptance_events WHERE day >= ? GROUP BY day
                    """,
                arguments: [dayKey(first)]
            )
        }
        let totals = Dictionary(rows.map { ($0["day"] as String, $0) }) { first, _ in first }
        return dates.map { date in
            let row = totals[dayKey(date)]
            return DailyStat(
                day: date,
                wordsAccepted: row?["words"] ?? 0,
                charactersAccepted: row?["characters"] ?? 0,
                acceptances: row?["acceptances"] ?? 0
            )
        }
    }

    public func wordsAcceptedToday() throws -> Int {
        try wordsAccepted(on: .now)
    }

    func wordsAccepted(on date: Date) throws -> Int {
        let day = dayKey(date)
        return try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(words), 0) FROM acceptance_events WHERE day = ?", arguments: [day]) ?? 0
        }
    }

    func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func twoDigits(_ value: Int?) -> String {
            let value = value ?? 0
            return value < 10 ? "0\(value)" : "\(value)"
        }
        return "\(parts.year ?? 0)-\(twoDigits(parts.month))-\(twoDigits(parts.day))"
    }

    public func snippets() throws -> [Snippet] {
        let rows = try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, triggerText, body, isEnabled FROM snippets ORDER BY triggerText, id")
        }
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"] as String) else {
                Self.log.error("Skipped a snippet with an unreadable id")
                return nil
            }
            return Snippet(id: id, trigger: row["triggerText"], body: row["body"], isEnabled: row["isEnabled"])
        }
    }

    public func save(_ snippet: Snippet) throws {
        try writer.write { db in
            let taken = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM snippets WHERE triggerText = ? AND id <> ?)",
                arguments: [snippet.trigger, snippet.id.uuidString]
            ) ?? false
            if taken { throw MemoryError.duplicateSnippetTrigger(snippet.trigger) }
            try db.execute(
                sql: """
                    INSERT INTO snippets (id, triggerText, body, isEnabled) VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        triggerText = excluded.triggerText, body = excluded.body, isEnabled = excluded.isEnabled
                    """,
                arguments: [snippet.id.uuidString, snippet.trigger, snippet.body, snippet.isEnabled]
            )
        }
    }

    public func deleteSnippet(id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM snippets WHERE id = ?", arguments: [id.uuidString])
        }
    }


    public func appRules() throws -> [AppRule] {
        let rows = try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT bundleID, rule FROM app_rules ORDER BY bundleID")
        }
        let decoder = JSONDecoder()
        return rows.compactMap { row in
            let bundleID: String = row["bundleID"]
            let json: String = row["rule"]
            do {
                return try decoder.decode(AppRule.self, from: Data(json.utf8))
            } catch {
                Self.log.error("Skipped the unreadable rule for \(bundleID, privacy: .public): \(error, privacy: .private)")
                return nil
            }
        }
    }

    public func save(_ rule: AppRule) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(rule), as: UTF8.self)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_rules (bundleID, rule, updatedAt) VALUES (?, ?, ?)
                    ON CONFLICT(bundleID) DO UPDATE SET rule = excluded.rule, updatedAt = excluded.updatedAt
                    """,
                arguments: [rule.bundleID, json, Date.now]
            )
        }
    }

    public func deleteRule(bundleID: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM app_rules WHERE bundleID = ?", arguments: [bundleID])
        }
    }
}
