import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Inference

final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var delay: Duration = .zero
    }

    static let replies = Mutex<[String: Reply]>([:])
    static let hits = Mutex<[String: Int]>([:])
    private let stopped = Atomic<Bool>(false)

    /// URL-less requests (from unusable resume data) go to URLSession's own handling, which fails them at once.
    override class func canInit(with request: URLRequest) -> Bool { request.url != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let name = request.url?.lastPathComponent ?? ""
        Self.hits.withLock { $0[name, default: 0] += 1 }
        let reply = Self.replies.withLock { $0[name] } ?? Reply(status: 404, body: Data())
        let delay = DispatchTimeInterval.milliseconds(Int(reply.delay.components.seconds * 1000 + reply.delay.components.attoseconds / 1_000_000_000_000_000))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard !stopped.load(ordering: .relaxed), let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: [
                      "Content-Length": "\(reply.body.count)", "ETag": "\"stub\"", "Accept-Ranges": "bytes",
                  ])
            else {
                if !stopped.load(ordering: .relaxed) { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped.store(true, ordering: .relaxed)
    }
}

@Suite struct DownloaderTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "gw-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    func makeDownloader() -> ModelDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ModelDownloader(folder: folder, configuration: configuration)
    }

    func makeSpec(_ reply: StubProtocol.Reply?) -> ModelSpec {
        let fileName = "\(UUID().uuidString).gguf"
        if let reply { StubProtocol.replies.withLock { $0[fileName] = reply } }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return ModelSpec(
            id: fileName, displayName: "Stub", family: .custom, repo: "stub/models", fileName: fileName,
            sizeBytes: Int64(body.count), sha256: digest, minMemoryGB: 0, minTier: 0, revision: "0123abc"
        )
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appending(path: name).path) }

    @Test func downloadsVerifiesAndInstalls() async throws {
        let spec = makeSpec(.init(status: 200, body: body))
        let url = try await makeDownloader().download(spec) { _ in }
        #expect(try Data(contentsOf: url) == body)
        #expect(!exists(spec.fileName + ".download") && !exists(spec.fileName + ".resume"))
    }

    @Test(arguments: [false, true]) func unusableResumeDataStartsOver(asPropertyList: Bool) async throws {
        let spec = makeSpec(.init(status: 200, body: body))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stale = asPropertyList
            ? try PropertyListSerialization.data(fromPropertyList: ["expired": true], format: .binary, options: 0)
            : Data("not resume data".utf8)
        try stale.write(to: folder.appending(path: spec.fileName + ".resume"))

        let url = try await makeDownloader().download(spec) { _ in }
        #expect(try Data(contentsOf: url) == body)
        #expect(!exists(spec.fileName + ".resume"))
    }

    @Test func httpErrorFailsWithoutLeftovers() async throws {
        let spec = makeSpec(.init(status: 403, body: Data("expired".utf8)))
        await #expect(throws: InferenceError.self) { try await makeDownloader().download(spec) { _ in } }
        #expect(!exists(spec.fileName) && !exists(spec.fileName + ".resume") && !exists(spec.fileName + ".download"))
    }

    @Test func secondDownloadOfTheSameModelIsRejected() async throws {
        let downloader = makeDownloader()
        let spec = makeSpec(.init(status: 200, body: body, delay: .milliseconds(400)))
        let first = Task { try await downloader.download(spec) { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: InferenceError.self) { try await downloader.download(spec) { _ in } }
        #expect(try Data(contentsOf: try await first.value) == body)
    }

    enum Stop: CaseIterable { case cancel, suspendAll, taskCancel }

    @Test(arguments: Stop.allCases) func cancelSuspendAndTaskCancelStopTheTransfer(stop: Stop) async throws {
        let downloader = makeDownloader()
        let spec = makeSpec(.init(status: 200, body: body, delay: .seconds(5)))
        let task = Task { try await downloader.download(spec) { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        switch stop {
        case .cancel: await downloader.cancel(spec)
        case .suspendAll: await downloader.suspendAll()
        case .taskCancel: task.cancel()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(!exists(spec.fileName))
        await downloader.suspendAll()
    }

    @Test func completeStagingFileIsVerifiedWithoutDownloading() async throws {
        let spec = makeSpec(nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try body.write(to: folder.appending(path: spec.fileName + ".download"))
        let url = try await makeDownloader().download(spec) { _ in }
        #expect(try Data(contentsOf: url) == body)
        #expect(StubProtocol.hits.withLock { $0[spec.fileName] } == nil)
    }

    @Test func checksumStopsWhenCancelled() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "hash.bin")
        try body.write(to: file)
        await #expect(throws: CancellationError.self) { try await ModelDownloader.sha256(of: file, isCancelled: { true }) }
    }

    @Test func spaceCheckNeedsSizePlusMargin() throws {
        #expect(throws: InferenceError.self) { try ModelDownloader.checkSpace(needed: 10, available: 9) }
        try ModelDownloader.checkSpace(needed: 10, available: 10)
        try ModelDownloader.checkSpace(needed: 10, available: nil)
    }
}
