import CryptoKit
import Foundation
import GRDB
import GWCore
import os

/// Opens the database file encrypted with SQLCipher. A plaintext file from an earlier version is encrypted in place.
/// A file that cannot be decrypted is moved aside and a new one started.
enum DatabaseFile {
    enum State {
        case missing, plaintext, encrypted
    }

    private static let log = Logger.gw("memory")
    private static let plaintextHeader = Data("SQLite format 3\0".utf8)

    static func open(_ url: URL, keys: any DatabaseKeyStore) throws -> DatabasePool {
        let path = url.path(percentEncoded: false)
        let temporary = path + ".encrypting"
        for leftover in [temporary, temporary + "-journal"] { try removeIfPresent(leftover) }
        switch try state(of: path) {
        case .missing:
            return try pool(path, key: keys.key() ?? newKey(in: keys))
        case .plaintext:
            let key = try keys.key() ?? newKey(in: keys)
            try encrypt(path, through: temporary, key: key)
            return try pool(path, key: key)
        case .encrypted:
            guard let key = try keys.key() else {
                try moveAside(path, because: "its key is missing from the keychain")
                return try pool(path, key: newKey(in: keys))
            }
            do {
                return try pool(path, key: key)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
                try moveAside(path, because: "the key in the keychain does not open it")
                return try pool(path, key: key)
            }
        }
    }

    private static func pool(_ path: String, key: Data) throws -> DatabasePool {
        try DatabasePool(path: path, configuration: MemoryStore.configuration(key: key))
    }

    /// The SQLCipher raw key form: 64 hex digits are used as the key as is, without a slow key derivation.
    static func passphrase(_ key: Data) -> String {
        "x'" + KeychainKeyStore.hex(key) + "'"
    }

    static func state(of path: String) throws -> State {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        let handle = try FileHandle(forReadingFrom: URL(filePath: path))
        defer {
            do { try handle.close() } catch { log.error("Closing the database file failed: \(error, privacy: .public)") }
        }
        let header = try handle.read(upToCount: plaintextHeader.count) ?? Data()
        if header.isEmpty { return .missing }
        return header == plaintextHeader ? .plaintext : .encrypted
    }

    private static func newKey(in keys: any DatabaseKeyStore) throws -> Data {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try keys.save(key)
        return key
    }

    private static func encrypt(_ path: String, through temporary: String, key: Data) throws {
        let start = ContinuousClock.now
        let plaintext = try DatabaseQueue(path: path)
        let rows = try plaintext.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
            try db.execute(sql: "ATTACH DATABASE ? AS encrypted KEY ?", arguments: [temporary, passphrase(key)])
            try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
            try db.execute(sql: "DETACH DATABASE encrypted")
            return try rowCounts(db)
        }
        try plaintext.close()
        let copy = try DatabaseQueue(path: temporary, configuration: MemoryStore.configuration(key: key))
        let copied = try copy.read(rowCounts)
        try copy.close()
        guard copied == rows else { throw MemoryError.encryptionLostRows }
        // The plaintext write-ahead log is empty after the checkpoint. Left beside the encrypted file it would be
        // read as its log, so it goes before the rename.
        for suffix in ["-wal", "-shm"] { try removeIfPresent(path + suffix) }
        guard rename(temporary, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        log.info("Encrypted the database in \(start.duration(to: .now), privacy: .public)")
    }

    private static func rowCounts(_ db: Database) throws -> [String: Int] {
        let tables = try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_schema WHERE type = 'table' AND rootpage > 0 AND name NOT LIKE 'sqlite_%'"
        )
        var counts: [String: Int] = [:]
        for table in tables {
            counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") ?? 0
        }
        return counts
    }

    private static func moveAside(_ path: String, because reason: String) throws {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.moveItem(atPath: path + suffix, toPath: "\(path).unreadable-\(stamp)\(suffix)")
        }
        log.error("Moved the database aside and started a new one, because \(reason, privacy: .public)")
    }

    private static func removeIfPresent(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}
