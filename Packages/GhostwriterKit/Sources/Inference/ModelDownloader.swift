import CryptoKit
import Foundation
import GWCore
import os
import Synchronization

public actor ModelDownloader {
    static let spaceMargin: Int64 = 512 << 20

    private let folder: URL
    private let finder: LocalModelFinder
    private let delegate = DownloadDelegate()
    private let session: URLSession
    private var jobs: [String: DownloadJob] = [:]
    private let log = Logger.gw("download")

    public init() {
        self.init(folder: AppPaths.models, configuration: Self.uncached, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Model bodies go straight to the partial file; a response cache would only hold a second copy.
    private static var uncached: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    init(folder: URL, configuration: URLSessionConfiguration, home: URL) {
        self.folder = folder
        finder = LocalModelFinder(home: home)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func download(_ spec: ModelSpec, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let remote = spec.downloadURL else { throw InferenceError.downloadFailed("\(spec.displayName) has no download source") }
        guard jobs[spec.id] == nil else { throw InferenceError.alreadyDownloading(spec.displayName) }
        let job = DownloadJob(resumeFile: folder.appending(path: spec.fileName + ".resume"))
        jobs[spec.id] = job
        defer { if jobs[spec.id] === job { jobs[spec.id] = nil } }
        do {
            return try await withTaskCancellationHandler {
                try await perform(spec, from: remote, job: job, progress: progress)
            } onCancel: {
                job.cancel()
            }
        } catch {
            if job.isDiscarded {
                removeIfPresent(job.resumeFile)
                removeIfPresent(folder.appending(path: spec.fileName + ".download"))
            }
            throw error
        }
    }

    private func perform(
        _ spec: ModelSpec, from remote: URL, job: DownloadJob, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appending(path: spec.fileName + ".download")
        let destination = folder.appending(path: spec.fileName)

        if Self.isDanglingLink(destination) {
            try FileManager.default.removeItem(at: destination)
        }
        if !FileManager.default.fileExists(atPath: destination.path),
           let copy = try await localCopy(of: spec, isCancelled: { job.isCancelled }) {
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: copy)
            log.notice("Linked \(spec.fileName, privacy: .public) to a copy already on this Mac")
            return destination
        }
        // A complete staging file is left behind when the app quits during the checksum; verify it again instead.
        if !Self.hasSize(spec.sizeBytes, staging) {
            try await transfer(from: remote, to: staging, spec: spec, job: job, progress: progress)
        }
        try job.checkCancellation()
        if let expected = spec.sha256 {
            let actual = try await Self.sha256(of: staging, isCancelled: { job.isCancelled })
            guard actual == expected else {
                removeIfPresent(staging)
                throw InferenceError.checksumMismatch(expected: expected, actual: actual)
            }
        }
        try job.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return destination
    }

    private func localCopy(of spec: ModelSpec, isCancelled: @escaping @Sendable () -> Bool) async throws -> URL? {
        guard let expected = spec.sha256 else { return nil }
        for candidate in finder.candidates(for: spec) where Self.hasSize(spec.sizeBytes, candidate) {
            do {
                if try await Self.sha256(of: candidate, isCancelled: isCancelled) == expected { return candidate }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("Reading a local copy of \(spec.fileName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    private static func isDanglingLink(_ url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// Downloads stopped by a quit or a failure, not by `cancel`.
    public func interrupted(among specs: [ModelSpec]) -> [ModelSpec] {
        specs.filter { spec in
            guard spec.downloadURL != nil,
                  !FileManager.default.fileExists(atPath: folder.appending(path: spec.fileName).path)
            else { return false }
            return [".resume", ".download"].contains { FileManager.default.fileExists(atPath: folder.appending(path: spec.fileName + $0).path) }
        }
    }

    public func cancel(_ spec: ModelSpec) {
        jobs[spec.id]?.cancel()
    }

    public func suspendAll() {
        for job in jobs.values { job.suspend() }
    }

    /// Each request goes to the stable resolve URL: the signed CDN URL it redirects to expires after about an hour.
    private func transfer(
        from remote: URL, to staging: URL, spec: ModelSpec, job: DownloadJob, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var resumePoint = resumePoint(of: staging, etagFile: job.resumeFile, size: spec.sizeBytes)
        try Self.checkSpace(needed: spec.sizeBytes - (resumePoint?.offset ?? 0) + Self.spaceMargin, available: availableSpace())
        while true {
            var request = URLRequest(url: remote)
            if let resumePoint {
                request.setValue("bytes=\(resumePoint.offset)-", forHTTPHeaderField: "Range")
                request.setValue(resumePoint.etag, forHTTPHeaderField: "If-Range")
            }
            let target = TransferTarget(
                staging: staging, etagFile: job.resumeFile, resumePoint: resumePoint, expectedBytes: spec.sizeBytes, progress: progress
            )
            let end: TransferEnd
            do {
                end = try await job.run(session.dataTask(with: request), delegate: delegate, target: target)
            } catch {
                if job.isCancelled || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw error
            }
            switch end {
            case .finished:
                removeIfPresent(job.resumeFile)
                return
            case .changed:
                log.notice("\(spec.fileName, privacy: .public) changed on the server, starting over")
                resumePoint = nil
            }
        }
    }

    private func resumePoint(of staging: URL, etagFile: URL, size: Int64) -> ResumePoint? {
        guard let offset = Self.fileSize(staging), offset > 0, offset < size,
              FileManager.default.fileExists(atPath: etagFile.path)
        else { return nil }
        do {
            guard let etag = Self.strongETag(try String(contentsOf: etagFile, encoding: .utf8)) else { return nil }
            return ResumePoint(offset: offset, etag: etag)
        } catch {
            log.error("Reading \(etagFile.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    fileprivate static func start(_ response: URLResponse, resuming resumePoint: ResumePoint?) -> TransferStart {
        guard let response = response as? HTTPURLResponse else { return .failed(status: 0) }
        let etag = strongETag(response.value(forHTTPHeaderField: "ETag"))
        switch response.statusCode {
        case 200:
            return .replace(etag: etag)
        case 206:
            guard let resumePoint else { return .failed(status: 206) }
            guard etag == resumePoint.etag, rangeStart(response) == resumePoint.offset else { return .changed }
            return .append(at: resumePoint.offset)
        default:
            return .failed(status: response.statusCode)
        }
    }

    /// If-Range accepts only strong validators; a weak ETag (`W/"..."`) cannot prove two byte ranges belong together.
    private static func strongETag(_ value: String?) -> String? {
        guard let value, value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""), !value.contains(where: \.isNewline)
        else { return nil }
        return value
    }

    private static func rangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let range = response.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes ") else { return nil }
        return Int64(range.dropFirst("bytes ".count).prefix { $0.isNumber })
    }

    static func checkSpace(needed: Int64, available: Int64?) throws {
        guard let available, available < needed else { return }
        throw InferenceError.insufficientSpace(needed: needed, available: available)
    }

    private func availableSpace() -> Int64? {
        do {
            return try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        } catch {
            log.error("Reading free space failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func hasSize(_ size: Int64, _ url: URL) -> Bool {
        size > 0 && fileSize(url) == size
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        } catch {
            Logger.gw("download").error("Reading the size of \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func sha256(of url: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var hasher = SHA256()
                    while true {
                        if isCancelled() { throw CancellationError() }
                        let done = try autoreleasepool {
                            guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return true }
                            hasher.update(data: chunk)
                            return false
                        }
                        if done { break }
                    }
                    continuation.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            log.error("Removing \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct ResumePoint: Equatable, Sendable {
    var offset: Int64
    var etag: String
}

private enum TransferStart: Equatable {
    case append(at: Int64)
    case replace(etag: String?)
    case changed
    case failed(status: Int)
}

private enum TransferEnd: Sendable {
    case finished
    case changed
}

private struct TransferTarget: Sendable {
    var staging: URL
    var etagFile: URL
    var resumePoint: ResumePoint?
    var expectedBytes: Int64
    var progress: @Sendable (Double) -> Void

    /// Truncates before saving the ETag, so a quit in between never pairs old bytes with the new ETag.
    func open(for start: TransferStart) throws -> (FileHandle, position: Int64)? {
        let offset: Int64
        switch start {
        case .append(let at): offset = at
        case .replace: offset = 0
        case .changed, .failed: return nil
        }
        if !FileManager.default.fileExists(atPath: staging.path) {
            FileManager.default.createFile(atPath: staging.path, contents: nil)
        }
        let file = try FileHandle(forWritingTo: staging)
        try file.truncate(atOffset: UInt64(offset))
        if case .replace(let etag) = start {
            if let etag {
                try etag.write(to: etagFile, atomically: true, encoding: .utf8)
            } else if FileManager.default.fileExists(atPath: etagFile.path) {
                try FileManager.default.removeItem(at: etagFile)
            }
        }
        return (file, offset)
    }
}

private final class DownloadJob: Sendable {
    private enum Stop { case cancel, suspend }

    let resumeFile: URL
    private let stop = Mutex<Stop?>(nil)
    private let current = Mutex<URLSessionDataTask?>(nil)

    init(resumeFile: URL) {
        self.resumeFile = resumeFile
    }

    var isCancelled: Bool { stop.withLock { $0 } != nil }
    var isDiscarded: Bool { stop.withLock { $0 } == .cancel }

    func checkCancellation() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    func run(_ task: URLSessionDataTask, delegate: DownloadDelegate, target: TransferTarget) async throws -> TransferEnd {
        current.withLock { $0 = task }
        defer { current.withLock { $0 = nil } }
        try checkCancellation()
        return try await delegate.run(task, target: target)
    }

    func cancel() {
        stop.withLock { $0 = .cancel }
        current.withLock { $0 }?.cancel()
    }

    /// Bytes reach the staging file as they arrive, so stopping the task is all a quit needs.
    func suspend() {
        guard stop.withLock({ stopped in
            guard stopped == nil else { return false }
            stopped = .suspend
            return true
        }) else { return }
        current.withLock { $0 }?.cancel()
    }
}

private final class DownloadDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct Pending: Sendable {
        var continuation: CheckedContinuation<TransferEnd, any Error>
        var target: TransferTarget
        var file: FileHandle?
        var position: Int64 = 0
        var end: Result<TransferEnd, any Error>?
    }

    private let pending = Mutex<[Int: Pending]>([:])

    func run(_ task: URLSessionDataTask, target: TransferTarget) async throws -> TransferEnd {
        try await withCheckedThrowingContinuation { continuation in
            pending.withLock { $0[task.taskIdentifier] = Pending(continuation: continuation, target: target) }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let id = dataTask.taskIdentifier
        guard let target = pending.withLock({ $0[id]?.target }) else { return completionHandler(.cancel) }
        let start = ModelDownloader.start(response, resuming: target.resumePoint)
        let opened: Result<(FileHandle, position: Int64)?, any Error> = Result { try target.open(for: start) }
        pending.withLock { entries in
            switch (start, opened) {
            case (_, .success(let (file, position)?)):
                entries[id]?.file = file
                entries[id]?.position = position
            case (.failed(let status), _):
                entries[id]?.end = .failure(InferenceError.downloadFailed("the server answered HTTP \(status)"))
            case (_, .failure(let error)):
                entries[id]?.end = .failure(error)
            default:
                entries[id]?.end = .success(.changed)
            }
        }
        completionHandler(pending.withLock { $0[id]?.file } == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        guard let entry = pending.withLock({ $0[id] }), entry.end == nil, let file = entry.file else { return }
        do {
            try file.write(contentsOf: data)
        } catch {
            pending.withLock { $0[id]?.end = .failure(error) }
            dataTask.cancel()
            return
        }
        let position = entry.position + Int64(data.count)
        pending.withLock { $0[id]?.position = position }
        guard entry.target.expectedBytes > 0 else { return }
        entry.target.progress(min(1, Double(position) / Double(entry.target.expectedBytes)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let entry = pending.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        var end = entry.end ?? error.map { .failure($0) } ?? .success(.finished)
        if let file = entry.file {
            do {
                try file.close()
            } catch {
                Logger.gw("download").error("Closing the staging file failed: \(error.localizedDescription, privacy: .public)")
                if case .success(.finished) = end { end = .failure(error) }
            }
        }
        entry.continuation.resume(with: end)
    }
}
