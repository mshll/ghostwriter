import CommonCrypto
import Foundation

/// Decrypts a database in the SQLCipher 4 default format into plain SQLite bytes,
/// applying the committed frames of its write-ahead log.
struct SQLCipherDecoder {
    enum Failure: Error, Equatable {
        case malformed
        case wrongKey
        case cryptoFailed(Int32)
    }

    static let pageSize = 4_096
    static let saltSize = 16
    static let ivSize = 16
    static let hmacSize = 64
    static let reserveSize = ivSize + hmacSize
    static let kdfIterations: UInt32 = 256_000
    static let keySize = 32
    static let plainHeader = Array("SQLite format 3\0".utf8)

    private let key: [UInt8]
    private let hmacKey: [UInt8]

    init(passphrase: Data, salt: some Collection<UInt8>) throws(Failure) {
        let salt = Array(salt)
        guard salt.count == Self.saltSize else { throw .malformed }
        key = try Self.pbkdf2(Array(passphrase), salt: salt, rounds: Self.kdfIterations)
        hmacKey = try Self.pbkdf2(key, salt: salt.map { $0 ^ 0x3a }, rounds: 2)
    }

    static func decrypt(database: Data, wal: Data?, passphrase: Data) throws(Failure) -> Data {
        let bytes = [UInt8](database)
        guard bytes.count >= pageSize, bytes.count.isMultiple(of: pageSize) else { throw .malformed }
        let decoder = try SQLCipherDecoder(passphrase: passphrase, salt: bytes[0..<saltSize])
        var pages: [[UInt8]] = []
        pages.reserveCapacity(bytes.count / pageSize)
        for start in stride(from: 0, to: bytes.count, by: pageSize) {
            guard let page = try decoder.decryptPage(bytes[start..<(start + pageSize)], number: pages.count + 1) else {
                throw .wrongKey
            }
            pages.append(page)
        }
        if let wal {
            try decoder.applyCommittedFrames(of: [UInt8](wal), to: &pages)
        }
        var plain = pages.flatMap { $0 }
        plain[18] = 1
        plain[19] = 1
        return Data(plain)
    }

    /// Returns nil when the page fails authentication. An all-zero page is one that incremental vacuum
    /// left unwritten, which SQLCipher also reads as zeros.
    func decryptPage(_ page: ArraySlice<UInt8>, number: Int) throws(Failure) -> [UInt8]? {
        let page = Array(page)
        guard page.count == Self.pageSize, number > 0 else { throw .malformed }
        if number > 1, page.allSatisfy({ $0 == 0 }) { return page }
        let offset = number == 1 ? Self.saltSize : 0
        let ivStart = Self.pageSize - Self.reserveSize
        let hmacStart = Self.pageSize - Self.hmacSize
        var littleEndianNumber = UInt32(number).littleEndian
        let authenticated = Array(page[offset..<hmacStart]) + withUnsafeBytes(of: &littleEndianNumber, Array.init)
        guard Self.hmac(authenticated, key: hmacKey) == Array(page[hmacStart...]) else { return nil }
        let plain = try Self.aesDecrypt(Array(page[offset..<ivStart]), key: key, iv: Array(page[ivStart..<hmacStart]))
        let head = number == 1 ? Self.plainHeader : []
        return head + plain + [UInt8](repeating: 0, count: Self.reserveSize)
    }

    private func applyCommittedFrames(of wal: [UInt8], to pages: inout [[UInt8]]) throws(Failure) {
        let headerSize = 32
        let frameHeaderSize = 24
        guard wal.count >= headerSize else { return }
        guard Self.bigEndian(wal, at: 8) == Self.pageSize else { throw .malformed }
        let salts = wal[16..<24]
        var pending: [Int: [UInt8]] = [:]
        var frame = headerSize
        while frame + frameHeaderSize + Self.pageSize <= wal.count {
            let number = Self.bigEndian(wal, at: frame)
            let committedPageCount = Self.bigEndian(wal, at: frame + 4)
            guard wal[(frame + 8)..<(frame + 16)].elementsEqual(salts), number > 0 else { break }
            let start = frame + frameHeaderSize
            guard let page = try decryptPage(wal[start..<(start + Self.pageSize)], number: number) else { break }
            pending[number] = page
            if committedPageCount > 0 {
                Self.apply(pending, pageCount: committedPageCount, to: &pages)
                pending = [:]
            }
            frame = start + Self.pageSize
        }
    }

    private static func apply(_ frames: [Int: [UInt8]], pageCount: Int, to pages: inout [[UInt8]]) {
        if pages.count > pageCount {
            pages.removeLast(pages.count - pageCount)
        } else if pages.count < pageCount {
            pages += Array(repeating: [UInt8](repeating: 0, count: pageSize), count: pageCount - pages.count)
        }
        for (number, page) in frames where number <= pageCount {
            pages[number - 1] = page
        }
    }

    private static func bigEndian(_ bytes: [UInt8], at index: Int) -> Int {
        bytes[index..<(index + 4)].reduce(0) { $0 << 8 | Int($1) }
    }

    private static func pbkdf2(_ password: [UInt8], salt: [UInt8], rounds: UInt32) throws(Failure) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: keySize)
        let status = password.withUnsafeBufferPointer { passwordBuffer in
            passwordBuffer.withMemoryRebound(to: CChar.self) { passwordChars in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordChars.baseAddress, passwordChars.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds,
                    &derived, derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw .cryptoFailed(status) }
        return derived
    }

    private static func hmac(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: hmacSize)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA512), key, key.count, data, data.count, &digest)
        return digest
    }

    private static func aesDecrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws(Failure) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
            key, key.count, iv, data, data.count, &output, output.count, &moved
        )
        guard status == kCCSuccess, moved == data.count else { throw .cryptoFailed(status) }
        return output
    }
}
