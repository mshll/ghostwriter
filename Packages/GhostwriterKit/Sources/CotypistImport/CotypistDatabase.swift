import Foundation
import GRDB
import GRDBSQLite
import GWCore
import Memory
import Prompting
import os

/// Reads writing history and per-app settings from a decrypted Cotypist database.
enum CotypistDatabase {
    enum Failure: Error, Equatable {
        case deserializeFailed(Int32)
    }

    private static let log = Logger.gw("CotypistImport")

    static func read(plain: Data) throws -> (sessions: [WritingSession], rules: [AppRule]) {
        let queue = try DatabaseQueue()
        return try queue.inDatabase { db in
            try deserialize(plain, into: db)
            return (try sessions(db), try rules(db))
        }
    }

    private static func deserialize(_ plain: Data, into db: Database) throws {
        guard let buffer = sqlite3_malloc64(UInt64(plain.count))?.assumingMemoryBound(to: UInt8.self) else {
            throw Failure.deserializeFailed(SQLITE_NOMEM)
        }
        plain.copyBytes(to: buffer, count: plain.count)
        let status = sqlite3_deserialize(
            db.sqliteConnection, "main", buffer, Int64(plain.count), Int64(plain.count),
            UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
        )
        guard status == SQLITE_OK else { throw Failure.deserializeFailed(status) }
    }

    private static func sessions(_ db: Database) throws -> [WritingSession] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, updatedAt, appBundleIdentifier, appProperties, textFieldProperties,
                       textUpToCursor, selectedText, textAfterCursor
                FROM user_inputs ORDER BY updatedAt
                """
        )
        return rows.compactMap { row in
            let text = ["textUpToCursor", "selectedText", "textAfterCursor"].compactMap { string(row, $0) }.joined()
            guard text.count >= WritingSession.minimumCharacters,
                  let id = string(row, "id"), let bundleID = string(row, "appBundleIdentifier"),
                  let updatedAt = Date.fromDatabaseValue(row["updatedAt"] as DatabaseValue)
            else { return nil }
            let app = decode(AppProperties.self, from: string(row, "appProperties"))
            let field = decode(FieldProperties.self, from: string(row, "textFieldProperties"))
            return WritingSession(
                key: "cotypist:\(id)",
                bundleID: bundleID,
                domain: app?.url.flatMap(URL.init(string:))?.host(),
                fieldLabel: field?.label,
                text: text,
                language: LanguageDetector.dominantLanguage(of: text),
                updatedAt: updatedAt
            )
        }
    }

    private static func rules(_ db: Database) throws -> [AppRule] {
        let prefix = "app:"
        let rows = try Row.fetchAll(db, sql: "SELECT id, overrides FROM app_overrides WHERE id LIKE 'app:%'")
        return rows.compactMap { row in
            guard let id = string(row, "id"), let overrides = decode(Overrides.self, from: string(row, "overrides")) else {
                return nil
            }
            let rule = overrides.rule(bundleID: String(id.dropFirst(prefix.count)))
            return rule == AppRule(bundleID: rule.bundleID) ? nil : rule
        }
    }

    /// Nil for NULL and for values of another type, which the typed `Row` subscripts would trap on.
    private static func string(_ row: Row, _ column: String) -> String? {
        String.fromDatabaseValue(row[column] as DatabaseValue)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            log.error("Skipped unreadable \(String(describing: type), privacy: .public): \(error, privacy: .private)")
            return nil
        }
    }
}

private struct AppProperties: Decodable {
    var url: String?
}

private struct FieldProperties: Decodable {
    var placeholderValue: String?
    var title: String?
    var description: String?

    var label: String? {
        [placeholderValue, title, description].lazy.compactMap { $0 }.first { !$0.isEmpty }
    }
}

private struct Overrides: Decodable {
    var completionsDisabled: Bool?
    var midLineCompletionsDisabled: Bool?
    var autocorrectDisabled: Bool?
    var tabShortcutsDisabled: Bool?
    var trainingDataCollectionDisabled: Bool?
    var customInstructions: String?

    func rule(bundleID: String) -> AppRule {
        AppRule(
            bundleID: bundleID,
            completionsEnabled: completionsDisabled.map(!),
            midLineEnabled: midLineCompletionsDisabled.map(!),
            recordWriting: trainingDataCollectionDisabled.map(!),
            tabAcceptEnabled: tabShortcutsDisabled.map(!),
            typoFixesEnabled: autocorrectDisabled.map(!),
            customInstructions: customInstructions.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
