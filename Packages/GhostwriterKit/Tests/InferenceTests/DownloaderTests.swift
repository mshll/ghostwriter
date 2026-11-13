import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Inference

/// Models the Hugging Face flow: the resolve URL redirects to a signed CDN URL that changes on every request
/// and stops working once expired. Like the real CDN, it answers Range requests with 206 whatever If-Range says.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var delay: Duration = .zero
        var stallAfter: Int?
        var etag = "\"stub\""
        var ignoresRange = false
    }

    static let replies = Mutex<[String: Reply]>([:])
    static let hits = Mutex<[String: Int]>([:])
    /// Each request for file data, as "<signature> <Range header or full>".
    static let fetches = Mutex<[String: [String]]>([:])
    private static let signatures = Mutex<[String: (latest: Int, expired: Int)]>([:])
    private let stopped = Atomic<Bool>(false)

    static func expireSignedURLs(of name: String) {
        signatures.withLock { entries in
            guard let latest = entries[name]?.latest else { return }
            entries[name]?.expired = latest
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let name = url.lastPathComponent
        if url.host == "huggingface.co" {
            redirect(url, name: name)
        } else {
            serve(url, name: name)
        }
    }

    /// The new request keeps the original headers, as URLSession does when it follows a real redirect.
    private func redirect(_ url: URL, name: String) {
        Self.hits.withLock { $0[name, default: 0] += 1 }
        let signature = Self.signatures.withLock { entry in
            entry[name, default: (0, 0)].latest += 1
            return entry[name, default: (0, 0)].latest
        }
        var signed = request
        signed.url = URL(string: "https://cdn.hf.co/\(signature)/\(name)")
        guard let location = signed.url,
              let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location.absoluteString])
        else { return }
        client?.urlProtocol(self, wasRedirectedTo: signed, redirectResponse: response)
    }

    private func serve(_ url: URL, name: String) {
        let signature = Int(url.pathComponents.dropLast().last ?? "") ?? 0
        let range = request.value(forHTTPHeaderField: "Range")
        Self.fetches.withLock { $0[name, default: []].append("\(signature) \(range ?? "full")") }
        let expired = Self.signatures.withLock { signature <= $0[name, default: (0, 0)].expired }
        let reply = expired
            ? Reply(status: 403, body: Data("expired".utf8))
            : Self.replies.withLock { $0[name] } ?? Reply(status: 404, body: Data())
        let offset = reply.ignoresRange ? 0 : range.flatMap { Int($0.dropFirst("bytes=".count).prefix { $0.isNumber }) } ?? 0
        let partial = reply.status == 200 && offset > 0
        let payload = partial ? reply.body.dropFirst(offset) : reply.body
        var fields = ["Content-Length": "\(payload.count)", "ETag": reply.etag, "Accept-Ranges": "bytes"]
        if partial { fields["Content-Range"] = "bytes \(offset)-\(reply.body.count - 1)/\(reply.body.count)" }
        let headers = fields
        let stallAfter = offset == 0 ? reply.stallAfter : nil
        let delay = DispatchTimeInterval.milliseconds(Int(reply.delay.components.seconds * 1000 + reply.delay.components.attoseconds / 1_000_000_000_000_000))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard !stopped.load(ordering: .relaxed),
                  let response = HTTPURLResponse(url: url, statusCode: partial ? 206 : reply.status, httpVersion: "HTTP/1.1", headerFields: headers)
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let stallAfter {
                client?.urlProtocol(self, didLoad: payload.prefix(stallAfter))
                return
            }
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped.store(true, ordering: .relaxed)
    }
}

@Suite struct DownloaderTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "gw-download-\(UUID().uuidString)", directoryHint: .isDirectory)
    let home = FileManager.default.temporaryDirectory.appending(path: "gw-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    func makeDownloader() -> ModelDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ModelDownloader(folder: folder, configuration: configuration, home: home)
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

    func fetches(_ spec: ModelSpec) -> [String] { StubProtocol.fetches.withLock { $0[spec.fileName] ?? [] } }

    @Test(arguments: [true, false]) func leftoversThatCannotBeValidatedStartOver(partial: Bool) async throws {
        let spec = makeSpec(.init(status: 200, body: body))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if partial {
            try body.prefix(50_000).write(to: folder.appending(path: spec.fileName + ".download"))
        } else {
            let resumeData = try PropertyListSerialization.data(fromPropertyList: ["expired": true], format: .binary, options: 0)
            try resumeData.write(to: folder.appending(path: spec.fileName + ".resume"))
        }

        let url = try await makeDownloader().download(spec) { _ in }
        #expect(try Data(contentsOf: url) == body)
        #expect(fetches(spec) == ["1 full"])
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

    func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    func startStalledDownload(_ downloader: ModelDownloader, _ spec: ModelSpec) async throws -> Task<URL, any Error> {
        let received = Mutex(false)
        let task = Task { try await downloader.download(spec) { _ in received.withLock { $0 = true } } }
        try await waitUntil { received.withLock { $0 } }
        return task
    }

    /// Quits after the first 50,000 bytes and lets the signed URL expire, then resumes with `reply`.
    func resumeAfterQuit(
        _ spec: ModelSpec, first: StubProtocol.Reply? = nil, then reply: StubProtocol.Reply
    ) async throws -> (URL, first: Double?) {
        let first = first ?? .init(status: 200, body: body, stallAfter: 50_000)
        StubProtocol.replies.withLock { $0[spec.fileName] = first }
        let downloader = makeDownloader()
        let task = try await startStalledDownload(downloader, spec)
        await downloader.suspendAll()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await downloader.interrupted(among: [spec]) == [spec])
        #expect(exists(spec.fileName + ".download"))

        StubProtocol.expireSignedURLs(of: spec.fileName)
        StubProtocol.replies.withLock { $0[spec.fileName] = reply }
        let firstProgress = Mutex<Double?>(nil)
        let url = try await makeDownloader().download(spec) { fraction in firstProgress.withLock { $0 = $0 ?? fraction } }
        return (url, firstProgress.withLock { $0 })
    }

    @Test func downloadStoppedByQuitResumesFromAFreshSignedURL() async throws {
        let spec = makeSpec(nil)
        let (url, firstProgress) = try await resumeAfterQuit(spec, then: .init(status: 200, body: body))
        #expect(try Data(contentsOf: url) == body)
        #expect(fetches(spec) == ["1 full", "2 bytes=50000-"])
        #expect(try #require(firstProgress) >= 0.25)
        #expect(await makeDownloader().interrupted(among: [spec]).isEmpty)
    }

    @Test func changedFileRestartsFromZero() async throws {
        let spec = makeSpec(nil)
        let older = StubProtocol.Reply(status: 200, body: Data(body.reversed()), stallAfter: 50_000)
        let (url, _) = try await resumeAfterQuit(spec, first: older, then: .init(status: 200, body: body, etag: "\"changed\""))
        #expect(try Data(contentsOf: url) == body)
        #expect(fetches(spec) == ["1 full", "2 bytes=50000-", "3 full"])
    }

    @Test func fullReplyToARangeRequestRestartsFromZero() async throws {
        let spec = makeSpec(nil)
        let (url, _) = try await resumeAfterQuit(spec, then: .init(status: 200, body: body, ignoresRange: true))
        #expect(try Data(contentsOf: url) == body)
        #expect(fetches(spec) == ["1 full", "2 bytes=50000-"])
    }

    @Test func weakETagIsNotTrustedForResuming() async throws {
        let spec = makeSpec(nil)
        let weak = StubProtocol.Reply(status: 200, body: body, stallAfter: 50_000, etag: "W/\"stub\"")
        let (url, _) = try await resumeAfterQuit(spec, first: weak, then: .init(status: 200, body: body))
        #expect(try Data(contentsOf: url) == body)
        #expect(fetches(spec) == ["1 full", "2 full"])
    }

    @Test func checksumMismatchNeverInstallsTheFile() async throws {
        let spec = makeSpec(.init(status: 200, body: Data(repeating: 7, count: body.count)))
        await #expect(throws: InferenceError.self) { try await makeDownloader().download(spec) { _ in } }
        #expect(!exists(spec.fileName) && !exists(spec.fileName + ".download") && !exists(spec.fileName + ".resume"))
    }

    @Test(arguments: [Stop.cancel, .taskCancel]) func cancelledDownloadLeavesNothingToResume(stop: Stop) async throws {
        let spec = makeSpec(.init(status: 200, body: body, stallAfter: 50_000))
        let downloader = makeDownloader()
        let task = try await startStalledDownload(downloader, spec)
        if stop == .cancel { await downloader.cancel(spec) } else { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!exists(spec.fileName + ".resume") && !exists(spec.fileName + ".download"))
        #expect(await downloader.interrupted(among: [spec]).isEmpty)
    }

    @Test func interruptedListsModelsWithLeftoversThatAreNotInstalled() async throws {
        let resumable = makeSpec(nil), staged = makeSpec(nil), untouched = makeSpec(nil), installed = makeSpec(nil)
        var custom = makeSpec(nil)
        custom.repo = ""
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for spec in [resumable, installed, custom] { try Data().write(to: folder.appending(path: spec.fileName + ".resume")) }
        try body.write(to: folder.appending(path: staged.fileName + ".download"))
        try body.write(to: folder.appending(path: installed.fileName))

        let specs = [resumable, staged, untouched, installed, custom]
        #expect(await makeDownloader().interrupted(among: specs) == [resumable, staged])
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

    func place(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test func verifiedLocalCopyIsLinkedWithoutDownloading() async throws {
        let spec = makeSpec(nil)
        let copy = try #require(LocalModelFinder(home: home).candidates(for: spec).last)
        try place(body, at: copy)
        let url = try await makeDownloader().download(spec) { _ in }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == copy.path)
        #expect(try Data(contentsOf: url) == body)
        #expect(StubProtocol.hits.withLock { $0[spec.fileName] } == nil)
    }

    @Test func localCopyWithOtherContentIsIgnored() async throws {
        let spec = makeSpec(.init(status: 200, body: body))
        let copy = try #require(LocalModelFinder(home: home).candidates(for: spec).first)
        try place(Data(repeating: 0, count: body.count), at: copy)
        let url = try await makeDownloader().download(spec) { _ in }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil)
        #expect(try Data(contentsOf: url) == body)
    }

    @Test func danglingLinkIsReplacedByDownload() async throws {
        let spec = makeSpec(.init(status: 200, body: body))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appending(path: spec.fileName), withDestinationURL: home.appending(path: "gone.gguf")
        )
        let url = try await makeDownloader().download(spec) { _ in }
        #expect(try Data(contentsOf: url) == body)
    }

    @Test func spaceCheckNeedsSizePlusMargin() throws {
        #expect(throws: InferenceError.self) { try ModelDownloader.checkSpace(needed: 10, available: 9) }
        try ModelDownloader.checkSpace(needed: 10, available: 10)
        try ModelDownloader.checkSpace(needed: 10, available: nil)
    }
}
