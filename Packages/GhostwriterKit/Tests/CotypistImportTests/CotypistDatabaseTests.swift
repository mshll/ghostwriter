import Foundation
import GRDB
import GWCore
import Memory
import Testing
@testable import CotypistImport

private let longText = "Thanks for sending the draft over. I read it twice and the structure works; the second section needs tighter wording."

private func plainDatabase(_ setUp: (Database) throws -> Void) throws -> Data {
    let url = URL.temporaryDirectory.appending(path: "cotypist-\(UUID().uuidString).db")
    defer {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Removing the test database failed: \(error)")
        }
    }
    let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
    try queue.write { db in
        try db.execute(sql: """
            CREATE TABLE user_inputs (
                id TEXT PRIMARY KEY NOT NULL, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
                appBundleIdentifier TEXT NOT NULL, appProperties TEXT NOT NULL, textFieldProperties TEXT NOT NULL,
                textUpToCursor TEXT NOT NULL, selectedText TEXT, textAfterCursor TEXT
            );
            CREATE TABLE app_overrides (id TEXT PRIMARY KEY NOT NULL, overrides TEXT NOT NULL, updatedAt DATETIME NOT NULL);
            """)
        try setUp(db)
    }
    try queue.close()
    return try Data(contentsOf: url)
}

private func insertInput(
    _ db: Database, id: String, app: String = "com.apple.mail", appProperties: String = "{}",
    field: String = "{}", before: String, selected: String? = nil, after: String? = nil,
    updatedAt: String = "2026-10-11 15:41:52.734"
) throws {
    try db.execute(
        sql: """
            INSERT INTO user_inputs
                (id, createdAt, updatedAt, appBundleIdentifier, appProperties, textFieldProperties,
                 textUpToCursor, selectedText, textAfterCursor)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
        arguments: [id, updatedAt, updatedAt, app, appProperties, field, before, selected, after]
    )
}

private func insertOverride(_ db: Database, id: String, _ json: String) throws {
    try db.execute(
        sql: "INSERT INTO app_overrides (id, overrides, updatedAt) VALUES (?, ?, '2026-10-11 15:39:44.849')",
        arguments: [id, json]
    )
}

@Suite struct CotypistDatabaseTests {
    @Test func mapsAWritingSession() throws {
        let plain = try plainDatabase { db in
            try insertInput(
                db, id: "A1", app: "com.google.Chrome",
                appProperties: #"{"url":"https://mail.example.com/inbox","name":"Chrome"}"#,
                field: #"{"description":"Message body","placeholderValue":"Write a reply"}"#,
                before: "Thanks for sending the draft over. ", selected: "I read it twice",
                after: " and the structure works; the second section needs tighter wording."
            )
        }
        let sessions = try CotypistDatabase.read(plain: plain).sessions
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.key == "cotypist:A1")
        #expect(session.bundleID == "com.google.Chrome")
        #expect(session.domain == "mail.example.com")
        #expect(session.fieldLabel == "Write a reply")
        #expect(session.text == longText)
        #expect(session.language == "en")
        #expect(session.updatedAt == Date(timeIntervalSince1970: 1_791_733_312.734))
    }

    @Test func skipsTextTooShortToLearnFrom() throws {
        let plain = try plainDatabase { db in
            try insertInput(db, id: "short", before: "See you soon.")
            try insertInput(db, id: "long", before: longText)
        }
        #expect(try CotypistDatabase.read(plain: plain).sessions.map(\.key) == ["cotypist:long"])
    }

    @Test func fallsBackToTheFieldDescriptionForTheLabel() throws {
        let plain = try plainDatabase { db in
            try insertInput(db, id: "A1", field: #"{"description":"Message","placeholderValue":""}"#, before: longText)
        }
        #expect(try CotypistDatabase.read(plain: plain).sessions.first?.fieldLabel == "Message")
    }

    @Test func mapsPerAppSettings() throws {
        let plain = try plainDatabase { db in
            try insertOverride(db, id: "app:com.apple.TextEdit", #"{"trainingDataCollectionDisabled":true,"tabShortcutsDisabled":true}"#)
            try insertOverride(db, id: "app:com.apple.mail", #"{"completionsDisabled":false,"autocorrectDisabled":true,"midLineCompletionsDisabled":true,"customInstructions":"Formal tone."}"#)
        }
        let rules = try CotypistDatabase.read(plain: plain).rules.sorted { $0.bundleID < $1.bundleID }
        #expect(rules == [
            AppRule(bundleID: "com.apple.TextEdit", recordWriting: false, tabAcceptEnabled: false),
            AppRule(
                bundleID: "com.apple.mail", completionsEnabled: true, midLineEnabled: false,
                typoFixesEnabled: false, customInstructions: "Formal tone."
            ),
        ])
    }

    @Test func skipsSiteDefaultAndEmptySettings() throws {
        let plain = try plainDatabase { db in
            try insertOverride(db, id: "default:", #"{"completionsDisabled":true}"#)
            try insertOverride(db, id: "domain:example.com", #"{"completionsDisabled":true}"#)
            try insertOverride(db, id: "app:com.apple.Notes", #"{"smartQuotesDisabled":true,"customInstructions":""}"#)
        }
        #expect(try CotypistDatabase.read(plain: plain).rules.isEmpty)
    }
}
