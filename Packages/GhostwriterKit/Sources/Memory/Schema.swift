import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // An INTEGER PRIMARY KEY keeps rowids stable across VACUUM; the external-content index depends on them.
            try db.execute(sql: """
                CREATE TABLE writing_sessions (
                    id INTEGER PRIMARY KEY,
                    key TEXT NOT NULL UNIQUE,
                    bundleID TEXT NOT NULL,
                    domain TEXT,
                    fieldLabel TEXT,
                    text TEXT NOT NULL,
                    language TEXT,
                    updatedAt DATETIME NOT NULL,
                    createdAt DATETIME NOT NULL
                );
                CREATE INDEX writing_sessions_on_updatedAt ON writing_sessions(updatedAt);
                CREATE INDEX writing_sessions_on_bundleID_updatedAt ON writing_sessions(bundleID, updatedAt);
                CREATE INDEX writing_sessions_on_language_updatedAt ON writing_sessions(language, updatedAt);

                CREATE TABLE acceptance_events (
                    id INTEGER PRIMARY KEY,
                    kind TEXT NOT NULL,
                    bundleID TEXT NOT NULL,
                    words INTEGER NOT NULL,
                    characters INTEGER NOT NULL,
                    date DATETIME NOT NULL,
                    day TEXT NOT NULL
                );
                CREATE INDEX acceptance_events_on_day ON acceptance_events(day);

                CREATE TABLE snippets (
                    id TEXT PRIMARY KEY,
                    triggerText TEXT NOT NULL UNIQUE,
                    body TEXT NOT NULL,
                    isEnabled BOOLEAN NOT NULL
                );

                CREATE TABLE app_rules (
                    bundleID TEXT PRIMARY KEY,
                    rule TEXT NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                """)
            try db.create(virtualTable: "writing_sessions_ft", using: FTS5()) { table in
                table.synchronize(withTable: "writing_sessions")
                table.tokenizer = .unicode61(diacritics: .remove)
                table.column("text")
            }
        }
        migrator.registerMigration("v2") { db in
            try db.dropFTS5SynchronizationTriggers(forTable: "writing_sessions_ft")
            try db.drop(table: "writing_sessions_ft")
            try db.alter(table: "writing_sessions") { table in
                table.add(column: "bigrams", .text).notNull().defaults(to: "")
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id, text FROM writing_sessions")
            for row in rows {
                let bigrams = Words.indexedBigrams(in: row["text"])
                guard !bigrams.isEmpty else { continue }
                try db.execute(
                    sql: "UPDATE writing_sessions SET bigrams = ? WHERE id = ?", arguments: [bigrams, row["id"] as Int64]
                )
            }
            try db.create(virtualTable: "writing_sessions_ft", using: FTS5()) { table in
                table.synchronize(withTable: "writing_sessions")
                table.tokenizer = .unicode61(diacritics: .remove)
                table.column("text")
                table.column("bigrams")
            }
            try db.execute(sql: "INSERT INTO writing_sessions_ft(writing_sessions_ft, rank) VALUES('secure-delete', 1)")
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE suggestion_counts (
                    day TEXT NOT NULL,
                    bundleID TEXT NOT NULL,
                    shown INTEGER NOT NULL DEFAULT 0,
                    used INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (day, bundleID)
                );
                """)
        }
        return migrator
    }
}
