import Foundation
import GWCore
import Memory
import Security
import os

public struct CotypistData: Sendable {
    public var instructions: String?
    public var sessions: [WritingSession]
    public var rules: [AppRule]
}

public enum CotypistError: Error, Equatable {
    case notFound
    case accessDenied
    case keychain(OSStatus)
    case unreadable
}

/// The personalization a local Cotypist install keeps: its database, the database key
/// in the login keychain, and its preferences.
public struct Cotypist: Sendable {
    static let bundleID = "app.cotypist.Cotypist"
    static let keychainService = "app.cotypist.Cotypist.database"
    static let keychainAccount = "database-key"
    private static let log = Logger.gw("CotypistImport")

    let supportDirectory: URL

    public static let local = Cotypist(
        supportDirectory: URL.homeDirectory.appending(path: "Library/Application Support/\(bundleID)", directoryHint: .isDirectory)
    )

    var databaseURL: URL { supportDirectory.appending(path: "cotypist.db") }
    var walURL: URL { supportDirectory.appending(path: "cotypist.db-wal") }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false))
    }

    public func instructions() -> String? {
        let value = CFPreferencesCopyAppValue("CompletionManager_userPrompt" as CFString, Self.bundleID as CFString)
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Asks macOS for the database key, which shows a keychain prompt, so call it off the main thread.
    public func load() throws(CotypistError) -> CotypistData {
        guard isInstalled else { throw .notFound }
        let passphrase = try databaseKey()
        do {
            return try read(passphrase: passphrase)
        } catch .unreadable {
            Self.log.info("Retrying the Cotypist import in case Cotypist was writing")
            return try read(passphrase: passphrase)
        } catch {
            throw error
        }
    }

    /// Reads the log before the database: a checkpoint in between then only copies frames that are
    /// applied again, so the two stay consistent.
    private func read(passphrase: Data) throws(CotypistError) -> CotypistData {
        let database: Data
        let wal: Data?
        do {
            wal = FileManager.default.fileExists(atPath: walURL.path(percentEncoded: false)) ? try Data(contentsOf: walURL) : nil
            database = try Data(contentsOf: databaseURL)
        } catch {
            Self.log.error("Reading the Cotypist database failed: \(error.localizedDescription, privacy: .public)")
            throw .notFound
        }
        do {
            let plain = try SQLCipherDecoder.decrypt(database: database, wal: wal, passphrase: passphrase)
            let (sessions, rules) = try CotypistDatabase.read(plain: plain)
            return CotypistData(instructions: instructions(), sessions: sessions, rules: rules)
        } catch {
            Self.log.error("Decoding the Cotypist database failed: \(String(describing: error), privacy: .public)")
            throw .unreadable
        }
    }

    private func databaseKey() throws(CotypistError) -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw .keychain(status) }
            return data
        case errSecItemNotFound: throw .notFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw .accessDenied
        default: throw .keychain(status)
        }
    }
}
