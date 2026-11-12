import CommonCrypto
import Foundation
import Testing
@testable import CotypistImport

private let pageSize = SQLCipherDecoder.pageSize
private let passphrase = Data("c2VjcmV0LXBhc3NwaHJhc2U=".utf8)
private let salt = (0..<16).map { UInt8($0 * 7 + 3) }

private func plainPage(_ number: Int, fill: UInt8) -> [UInt8] {
    var page = [UInt8](repeating: fill, count: pageSize - SQLCipherDecoder.reserveSize)
    if number == 1 { page.replaceSubrange(0..<16, with: SQLCipherDecoder.plainHeader) }
    return page + [UInt8](repeating: 0, count: SQLCipherDecoder.reserveSize)
}

private func encrypt(_ plain: [UInt8], number: Int) -> [UInt8] {
    let key = derive(Array(passphrase), salt: salt, rounds: SQLCipherDecoder.kdfIterations)
    let hmacKey = derive(key, salt: salt.map { $0 ^ 0x3a }, rounds: 2)
    let offset = number == 1 ? 16 : 0
    let body = Array(plain[offset..<(pageSize - SQLCipherDecoder.reserveSize)])
    let iv = (0..<16).map { UInt8(($0 + number) & 0xff) }
    var cipher = [UInt8](repeating: 0, count: body.count)
    var moved = 0
    _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, key, key.count, iv, body, body.count, &cipher, cipher.count, &moved)
    var littleEndianNumber = UInt32(number).littleEndian
    let authenticated = cipher + iv + withUnsafeBytes(of: &littleEndianNumber, Array.init)
    var mac = [UInt8](repeating: 0, count: 64)
    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA512), hmacKey, hmacKey.count, authenticated, authenticated.count, &mac)
    return (number == 1 ? salt : []) + cipher + iv + mac
}

private func derive(_ password: [UInt8], salt: [UInt8], rounds: UInt32) -> [UInt8] {
    var derived = [UInt8](repeating: 0, count: 32)
    _ = password.withUnsafeBufferPointer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { chars in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), chars.baseAddress, chars.count, salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds, &derived, derived.count
            )
        }
    }
    return derived
}

private func bigEndian(_ value: Int) -> [UInt8] {
    [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
}

private let walSalts: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

private func wal(_ frames: [(number: Int, committedPageCount: Int, page: [UInt8], salts: [UInt8])]) -> Data {
    var bytes = bigEndian(0x377f0682) + bigEndian(3_007_000) + bigEndian(pageSize) + bigEndian(0) + walSalts + bigEndian(0) + bigEndian(0)
    for frame in frames {
        bytes += bigEndian(frame.number) + bigEndian(frame.committedPageCount) + frame.salts + bigEndian(0) + bigEndian(0)
        bytes += encrypt(frame.page, number: frame.number)
    }
    return Data(bytes)
}

private func asPlainOutput(_ pages: [[UInt8]]) -> Data {
    var bytes = pages.flatMap { $0 }
    bytes[18] = 1
    bytes[19] = 1
    return Data(bytes)
}

@Suite struct SQLCipherDecoderTests {
    let pages = [plainPage(1, fill: 0x11), plainPage(2, fill: 0x22), plainPage(3, fill: 0x33)]
    var database: Data { Data(pages.enumerated().flatMap { encrypt($1, number: $0 + 1) }) }

    @Test func decryptsEveryPage() throws {
        let plain = try SQLCipherDecoder.decrypt(database: database, wal: nil, passphrase: passphrase)
        #expect(plain == asPlainOutput(pages))
    }

    @Test func rejectsTheWrongPassphrase() {
        #expect(throws: SQLCipherDecoder.Failure.wrongKey) {
            try SQLCipherDecoder.decrypt(database: database, wal: nil, passphrase: Data("wrong".utf8))
        }
    }

    @Test func rejectsATruncatedFile() {
        #expect(throws: SQLCipherDecoder.Failure.malformed) {
            try SQLCipherDecoder.decrypt(database: database.prefix(pageSize + 10), wal: nil, passphrase: passphrase)
        }
    }

    @Test func appliesCommittedLogFramesAndGrowsTheFile() throws {
        let log = wal([
            (2, 0, plainPage(2, fill: 0xa2), walSalts),
            (4, 4, plainPage(4, fill: 0xa4), walSalts),
        ])
        let plain = try SQLCipherDecoder.decrypt(database: database, wal: log, passphrase: passphrase)
        #expect(plain == asPlainOutput([pages[0], plainPage(2, fill: 0xa2), pages[2], plainPage(4, fill: 0xa4)]))
    }

    @Test func ignoresFramesAfterTheLastCommit() throws {
        let log = wal([
            (2, 3, plainPage(2, fill: 0xa2), walSalts),
            (3, 0, plainPage(3, fill: 0xa3), walSalts),
        ])
        let plain = try SQLCipherDecoder.decrypt(database: database, wal: log, passphrase: passphrase)
        #expect(plain == asPlainOutput([pages[0], plainPage(2, fill: 0xa2), pages[2]]))
    }

    @Test func stopsAtFramesFromAnEarlierLogGeneration() throws {
        let log = wal([
            (2, 3, plainPage(2, fill: 0xa2), walSalts),
            (3, 3, plainPage(3, fill: 0xa3), [9, 9, 9, 9, 9, 9, 9, 9]),
        ])
        let plain = try SQLCipherDecoder.decrypt(database: database, wal: log, passphrase: passphrase)
        #expect(plain == asPlainOutput([pages[0], plainPage(2, fill: 0xa2), pages[2]]))
    }

    @Test func dropsPagesBeyondACommitThatShrinksTheFile() throws {
        let log = wal([(1, 2, plainPage(1, fill: 0xa1), walSalts)])
        let plain = try SQLCipherDecoder.decrypt(database: database, wal: log, passphrase: passphrase)
        #expect(plain == asPlainOutput([plainPage(1, fill: 0xa1), pages[1]]))
    }
}
