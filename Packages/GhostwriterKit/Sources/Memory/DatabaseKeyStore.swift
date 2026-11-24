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

/// A generic password in the login keychain, saved as hex text so `security find-generic-password -w` prints it. The data protection keychain needs entitlements from a provisioning
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
            guard let data = result as? Data, let key = Self.bytes(fromHex: data) else { throw KeychainError.unexpectedValue }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    public func save(_ key: Data) throws {
        var item = query
        item[kSecValueData] = Data(Self.hex(key).utf8)
        item[kSecAttrLabel] = "Ghostwriter database key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(fromHex text: Data) -> Data? {
        guard text.count.isMultiple(of: 2), let string = String(data: text, encoding: .ascii) else { return nil }
        var bytes = Data(capacity: text.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
