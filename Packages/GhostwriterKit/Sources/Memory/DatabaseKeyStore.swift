import Foundation
import Security

public protocol DatabaseKeyStore: Sendable {
    /// Nil when no key was saved yet.
    func key() throws -> Data?
    func save(_ key: Data) throws
}

public enum KeychainError: LocalizedError, Equatable {
    case status(OSStatus)
    case unexpectedValue

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            "The keychain returned an error: \(SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)")"
        case .unexpectedValue: "The database key in the keychain is not readable."
        }
    }
}

/// A generic password in the login keychain. The data protection keychain needs entitlements from a provisioning
/// profile, which a Developer ID app without one cannot use.
public struct KeychainKeyStore: DatabaseKeyStore {
    let service: String
    let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func key() throws -> Data? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unexpectedValue }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    public func save(_ key: Data) throws {
        var item = query
        item[kSecValueData] = key
        item[kSecAttrLabel] = "Ghostwriter database key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
}
