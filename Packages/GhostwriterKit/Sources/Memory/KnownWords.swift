import GRDB

extension MemoryStore {
    /// Writing sessions whose text contains `word`, compared like the full-text index: lowercased, without Latin diacritics.
    public func sessionCount(containing word: String) throws -> Int {
        let phrase = "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return try writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM writing_sessions_ft WHERE writing_sessions_ft MATCH ?",
                arguments: ["text : " + phrase]
            ) ?? 0
        }
    }
}
