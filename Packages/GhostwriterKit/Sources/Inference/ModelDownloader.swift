import CryptoKit
import Foundation
import GWCore
import os
import Synchronization

public actor ModelDownloader {
    static let spaceMargin: Int64 = 512 << 20

    private let folder: URL
    private let delegate = DownloadDelegate()
    private let session: URLSession
    private var jobs: [String: DownloadJob] = [:]
    private let log = Logger.gw("download")

    public init() {
        self.init(folder: AppPaths.models, configuration: .default)
    }

    init(folder: URL, configuration: URLSessionConfiguration) {
        self.folder = folder
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func download(_ spec: ModelSpec, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let remote = spec.downloadURL else { throw InferenceError.downloadFailed("\(spec.displayName) has no download source") }
        guard jobs[spec.id] == nil else { throw InferenceError.alreadyDownloading(spec.displayName) }
        let job = DownloadJob(resumeFile: folder.appending(path: spec.fileName + ".resume"))
        jobs[spec.id] = job
        defer { if jobs[spec.id] === job { jobs[spec.id] = nil } }
        return try await withTaskCancellationHandler {
            try await perform(spec, from: remote, job: job, progress: progress)
        } onCancel: {
            job.cancel()
        }
    }

    private func perform(
        _ spec: ModelSpec, from remote: URL, job: DownloadJob, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appending(path: spec.fileName + ".download")
        let destination = folder.appending(path: spec.fileName)

        // A complete staging file is left behind when a cancel lands during the checksum; verify it again instead.
        if !Self.hasSize(spec.sizeBytes, staging) {
            try Self.checkSpace(needed: spec.sizeBytes + Self.spaceMargin, available: availableSpace())
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

    public func cancel(_ spec: ModelSpec) {
        jobs[spec.id]?.cancel()
    }

    public func suspendAll() async {
        for job in jobs.values { await job.suspend() }
    }

    private func transfer(
        from remote: URL, to staging: URL, spec: ModelSpec, job: DownloadJob, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var resumeData = loadResumeData(job.resumeFile)
        while true {
            let resuming = resumeData != nil
            let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: remote)
            do {
                try await job.run(task, delegate: delegate, destination: staging, expectedBytes: spec.sizeBytes, progress: progress)
                removeIfPresent(job.resumeFile)
                return
            } catch {
                let fresh = (error as? URLError)?.downloadTaskResumeData
                if job.isCancelled || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    if let fresh { Self.store(fresh, at: job.resumeFile) }
                    throw CancellationError()
                }
                if let fresh {
                    Self.store(fresh, at: job.resumeFile)
                    throw error
                }
                removeIfPresent(job.resumeFile)
                guard resuming else { throw error }
                log.notice("Resuming \(spec.fileName, privacy: .public) failed, starting over: \(error.localizedDescription, privacy: .public)")
                resumeData = nil
            }
        }
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
        guard size > 0, FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) == size
        } catch {
            Logger.gw("download").error("Reading the size of \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
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

    /// URLSession raises an Objective-C exception on resume data that is not a property list dictionary,
    /// so anything else is discarded.
    private func loadResumeData(_ url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            if try PropertyListSerialization.propertyList(from: data, format: nil) is [String: Any] { return data }
            log.error("Discarding malformed resume data \(url.lastPathComponent, privacy: .public)")
        } catch {
            log.error("Discarding unreadable resume data \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        removeIfPresent(url)
        return nil
    }

    static func store(_ data: Data, at url: URL) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.gw("download").error("Saving resume data failed: \(error.localizedDescription, privacy: .public)")
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

private final class DownloadJob: Sendable {
    let resumeFile: URL
    private let cancelled = Atomic<Bool>(false)
    private let current = Mutex<URLSessionDownloadTask?>(nil)

    init(resumeFile: URL) {
        self.resumeFile = resumeFile
    }

    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    func checkCancellation() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    func run(
        _ task: URLSessionDownloadTask, delegate: DownloadDelegate, destination: URL, expectedBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        current.withLock { $0 = task }
        defer { current.withLock { $0 = nil } }
        try checkCancellation()
        try await delegate.run(task, destination: destination, expectedBytes: expectedBytes, progress: progress)
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        let resumeFile = resumeFile
        current.withLock { $0 }?.cancel(byProducingResumeData: { data in
            if let data { ModelDownloader.store(data, at: resumeFile) }
        })
    }

    func suspend() async {
        cancelled.store(true, ordering: .relaxed)
        guard let task = current.withLock({ $0 }) else { return }
        let resumeFile = resumeFile
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            task.cancel(byProducingResumeData: { data in
                if let data { ModelDownloader.store(data, at: resumeFile) }
                continuation.resume()
            })
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct Pending: Sendable {
        var continuation: CheckedContinuation<Void, any Error>
        var destination: URL
        var expectedBytes: Int64
        var progress: @Sendable (Double) -> Void
        var failure: (any Error)?
    }

    private let pending = Mutex<[Int: Pending]>([:])

    func run(
        _ task: URLSessionDownloadTask, destination: URL, expectedBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending.withLock {
                $0[task.taskIdentifier] = Pending(
                    continuation: continuation, destination: destination, expectedBytes: expectedBytes, progress: progress
                )
            }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let entry = pending.withLock({ $0[downloadTask.taskIdentifier] }) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : entry.expectedBytes
        guard total > 0 else { return }
        entry.progress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    /// Also called for HTTP error statuses: URLSession reports only client-side failures as errors.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let entry = pending.withLock({ $0[downloadTask.taskIdentifier] }) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let failure: (any Error)?
        if !(200..<300).contains(status) {
            failure = InferenceError.downloadFailed("the server answered HTTP \(status)")
        } else {
            do {
                if FileManager.default.fileExists(atPath: entry.destination.path) {
                    try FileManager.default.removeItem(at: entry.destination)
                }
                try FileManager.default.moveItem(at: location, to: entry.destination)
                failure = nil
            } catch {
                failure = error
            }
        }
        pending.withLock { $0[downloadTask.taskIdentifier]?.failure = failure }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let entry = pending.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error = error ?? entry.failure {
            entry.continuation.resume(throwing: error)
        } else {
            entry.continuation.resume()
        }
    }
}
