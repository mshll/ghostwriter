import CryptoKit
import Foundation
import GRDB
import GWCore
import Security
import Synchronization
import Testing
@testable import Memory

final class TestKeyStore: DatabaseKeyStore {
    let stored: Mutex<Data?>

    init(_ key: Data? = nil) {
        stored = Mutex(key)
    }

    func key() throws -> Data? { stored.withLock { $0 } }
    func save(_ key: Data) throws { stored.withLock { $0 = key } }
}

struct LockedKeyStore: DatabaseKeyStore {
    func key() throws -> Data? { throw KeychainError.status(errSecInteractionNotAllowed) }
    func save(_ key: Data) throws { throw KeychainError.status(errSecInteractionNotAllowed) }
}

struct DatabaseEncryptionTests {
    let folder = URL.temporaryDirectory.appending(path: "encryption-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var url: URL { folder.appending(path: "store.sqlite") }
    var path: String { url.path(percentEncoded: false) }
    let marker = "zygomorphicquokka"

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func removeFolder() {
        do { try FileManager.default.removeItem(at: folder) } catch { Issue.record(error) }
    }

    func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
    }

    func header() throws -> Data {
        try Data(contentsOf: url).prefix(16)
    }

    func filesContainMarker() throws -> Bool {
        try ["", "-wal"].contains { suffix in
            guard FileManager.default.fileExists(atPath: path + suffix) else { return false }
            return try Data(contentsOf: URL(filePath: path + suffix)).range(of: Data(marker.utf8)) != nil
        }
    }

    func matches(_ store: MemoryStore, _ word: String) throws -> Int {
        try store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM writing_sessions_ft WHERE writing_sessions_ft MATCH ?", arguments: [word]) ?? 0
        }
    }

    func plaintextStore() throws -> MemoryStore {
        try MemoryStore(writer: DatabasePool(path: path, configuration: MemoryStore.configuration(key: nil)))
    }

    @Test func newDatabaseIsEncryptedAndSearchable() throws {
        defer { removeFolder() }
        let keys = TestKeyStore()
        let store = try MemoryStore(url: url, keys: keys)
        try store.upsertSession(session("secret", topics[0] + " The \(marker) plan stays private."))
        #expect(try keys.key()?.count == 32)
        #expect(try Data(contentsOf: URL(filePath: path + "-wal")).count > 0)
        #expect(try header() != Data("SQLite format 3\0".utf8))
        #expect(try !filesContainMarker())
        #expect(try matches(store, marker) == 1)
    }

    @Test func plaintextDatabaseIsEncryptedWithAllItsRows() throws {
        defer { removeFolder() }
        do {
            let plain = try plaintextStore()
            for (index, text) in topics.enumerated() { try plain.upsertSession(session("t\(index)", text)) }
            try plain.upsertSession(session("secret", topics[0] + " The \(marker) plan stays private."))
            try plain.recordAcceptance(AcceptanceEvent(kind: .word, bundleID: "com.apple.mail", words: 2, characters: 9, date: .now))
            try plain.recordSuggestion(.shown, bundleID: "com.apple.mail")
            try plain.save(Snippet(trigger: ";sig", body: "Best regards"))
        }
        #expect(try header() == Data("SQLite format 3\0".utf8))
        #expect(try filesContainMarker())

        let store = try MemoryStore(url: url, keys: TestKeyStore())
        #expect(try header() != Data("SQLite format 3\0".utf8))
        #expect(try !filesContainMarker())
        #expect(try store.writingCount(bundleID: nil) == topics.count + 1)
        #expect(try store.wordsAcceptedToday() == 2)
        #expect(try store.appStats(days: 1).first?.suggestionsShown == 1)
        #expect(try store.snippets().map(\.body) == ["Best regards"])
        #expect(try matches(store, marker) == 1)
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO writing_sessions_ft(writing_sessions_ft, rank) VALUES('integrity-check', 1)")
        }

        try store.upsertSession(session("new", topics[1] + " A second marmalade note."))
        #expect(try matches(store, "marmalade") == 1)
        #expect(try files().allSatisfy { !$0.contains("encrypting") })
    }

    @Test func plaintextDatabaseWithAnUncheckpointedLogIsEncrypted() throws {
        defer { removeFolder() }
        let source = folder.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourcePath = source.appending(path: "store.sqlite").path(percentEncoded: false)
        let plain = try MemoryStore(writer: DatabasePool(path: sourcePath, configuration: MemoryStore.configuration(key: nil)))
        for (index, text) in topics.enumerated() { try plain.upsertSession(session("t\(index)", text)) }
        try plain.upsertSession(session("late", topics[2] + " A \(marker) note."))
        for suffix in ["", "-wal", "-shm"] { try FileManager.default.copyItem(atPath: sourcePath + suffix, toPath: path + suffix) }
        withExtendedLifetime(plain) {}
        #expect(try Data(contentsOf: URL(filePath: path + "-wal")).range(of: Data(marker.utf8)) != nil)

        let store = try MemoryStore(url: url, keys: TestKeyStore())
        #expect(try store.writingCount(bundleID: nil) == topics.count + 1)
        #expect(try matches(store, marker) == 1)
        #expect(try !filesContainMarker())
    }

    @Test func eraseWorksOnAnEncryptedFile() throws {
        defer { removeFolder() }
        let keys = TestKeyStore()
        do {
            let store = try MemoryStore(url: url, keys: keys)
            try store.upsertSession(session("secret", topics[0] + " The \(marker) plan.", app: "com.apple.Notes"))
            for (index, text) in topics.enumerated() { try store.upsertSession(session("t\(index)", text)) }
            try store.eraseWriting(bundleID: "com.apple.Notes")
            #expect(try matches(store, marker) == 0)
            #expect(try store.writingCount(bundleID: nil) == topics.count)
            try store.eraseWriting(bundleID: nil)
            #expect(try store.writingCount(bundleID: nil) == 0)
        }
        #expect(try header() != Data("SQLite format 3\0".utf8))
        let reopened = try MemoryStore(url: url, keys: keys)
        #expect(try reopened.writingCount(bundleID: nil) == 0)
        try reopened.upsertSession(session("after", topics[1]))
        #expect(try reopened.writingCount(bundleID: nil) == 1)
        #expect(try files().allSatisfy { !$0.contains("unreadable") })
    }

    @Test func leftoverCopyFromAnInterruptedEncryptionIsRedone() throws {
        defer { removeFolder() }
        do { try plaintextStore().upsertSession(session("a", topics[0])) }
        try Data("half-written".utf8).write(to: URL(filePath: path + ".encrypting"))
        let store = try MemoryStore(url: url, keys: TestKeyStore())
        #expect(try store.writingCount(bundleID: nil) == 1)
        #expect(try files().allSatisfy { !$0.contains("encrypting") })
    }

    @Test func missingKeyMovesTheFileAsideAndStartsFresh() throws {
        defer { removeFolder() }
        do { try MemoryStore(url: url, keys: TestKeyStore()).upsertSession(session("a", topics[0])) }
        let keys = TestKeyStore()
        let store = try MemoryStore(url: url, keys: keys)
        #expect(try store.writingCount(bundleID: nil) == 0)
        #expect(try keys.key() != nil)
        #expect(try files().contains { $0.hasPrefix("store.sqlite.unreadable-") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
    }

    @Test func wrongKeyMovesTheFileAsideAndKeepsTheKey() throws {
        defer { removeFolder() }
        do { try MemoryStore(url: url, keys: TestKeyStore()).upsertSession(session("a", topics[0])) }
        let other = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let keys = TestKeyStore(other)
        let store = try MemoryStore(url: url, keys: keys)
        try store.upsertSession(session("b", topics[1]))
        #expect(try store.writingCount(bundleID: nil) == 1)
        #expect(try keys.key() == other)
        #expect(try files().contains { $0.hasPrefix("store.sqlite.unreadable-") })
    }

    @Test(arguments: [false, true])
    func keychainErrorLeavesTheFileAlone(encrypted: Bool) throws {
        defer { removeFolder() }
        if encrypted {
            try MemoryStore(url: url, keys: TestKeyStore()).upsertSession(session("a", topics[0]))
        } else {
            try plaintextStore().upsertSession(session("a", topics[0]))
        }
        let before = try files()
        let bytes = try Data(contentsOf: url)
        #expect(throws: KeychainError.status(errSecInteractionNotAllowed)) { try MemoryStore(url: url, keys: LockedKeyStore()) }
        #expect(try files() == before)
        #expect(try Data(contentsOf: url) == bytes)
    }
}

@Suite struct KeychainKeyFormatTests {
    @Test func hexRoundTrips() {
        let key = Data((0..<32).map { UInt8($0 * 8 % 256) })
        let text = Data(KeychainKeyStore.hex(key).utf8)
        #expect(text.count == 64)
        #expect(KeychainKeyStore.bytes(fromHex: text) == key)
    }

    @Test func rejectsTextThatIsNotHex() {
        #expect(KeychainKeyStore.bytes(fromHex: Data("abc".utf8)) == nil)
        #expect(KeychainKeyStore.bytes(fromHex: Data("zz".utf8)) == nil)
    }
}
