import CoreGraphics
import Foundation
import GWCore
import os
import Synchronization

public struct ScreenContextOptions: Sendable, Hashable {
    public var allowOCR: Bool = true
    public var maxCharacters: Int = 2400
    public var ocrBelowAXCharacters: Int = 200
    public var language: String?

    public init() {}
}

public actor ScreenContextProvider {
    static let freshness: Duration = .seconds(5)
    static let entryLifetime: Duration = .seconds(60)
    static let ocrTimeout: Duration = .seconds(3)
    static let declinedPause: Duration = .seconds(3600)

    private struct Entry {
        var axChunks: [TextChunk]
        var window: WindowKey
        var windowFrame: CGRect
        var fetchedAt: ContinuousClock.Instant
    }

    private struct OCRBackoff {
        var failures: Int
        var retryAt: ContinuousClock.Instant
    }

    private let logger = Logger.gw("ScreenContext")
    private var cache: [FieldID: Entry] = [:]
    private var scans: [FieldID: Task<Entry, Never>] = [:]
    private var windowReads = WindowReads()
    private var pendingOCR: [WindowKey: (claim: ContinuousClock.Instant, task: Task<Void, Never>)] = [:]
    private var ocrBackoff: [WindowKey: OCRBackoff] = [:]
    private var ocrDeclinedUntil: ContinuousClock.Instant?
    private var ocrSlot = OCRSlot()
    private var summary: String?

    public init() {}

    public func text(for snapshot: FieldSnapshot, options: ScreenContextOptions) async -> String? {
        guard snapshot.app.pid != getpid() else { return nil }
        let entry: Entry
        if let cached = cache[snapshot.id], ContinuousClock.now - cached.fetchedAt < Self.entryLifetime {
            entry = cached
            if ContinuousClock.now - cached.fetchedAt > Self.freshness, scans[snapshot.id] == nil {
                scans[snapshot.id] = Task { await scanAndStore(snapshot, options) }
            }
        } else if let running = scans[snapshot.id] {
            entry = await running.value
        } else {
            let task = Task { await scanAndStore(snapshot, options) }
            scans[snapshot.id] = task
            entry = await task.value
        }
        let chunks = ocrChunks(for: snapshot, entry, at: .now) ?? entry.axChunks
        return ScreenText.render(chunks, for: snapshot, maxCharacters: options.maxCharacters)
    }

    public func textAfterOCR(for snapshot: FieldSnapshot, options: ScreenContextOptions) async -> String? {
        guard let window = cache[snapshot.id]?.window else { return nil }
        if let pending = pendingOCR[window] { await pending.task.value }
        guard let entry = cache[snapshot.id], let chunks = ocrChunks(for: snapshot, entry, at: .now) else { return nil }
        return ScreenText.render(chunks, for: snapshot, maxCharacters: options.maxCharacters)
    }

    private func ocrChunks(for snapshot: FieldSnapshot, _ entry: Entry, at now: ContinuousClock.Instant) -> [TextChunk]? {
        guard let chunks = windowReads.chunks(of: entry.window, outside: snapshot.fieldFrame, at: now),
              characters(chunks) > characters(entry.axChunks) else { return nil }
        return chunks
    }

    public func lastScanSummary() -> String? { summary }

    public static func ocrText(
        of image: CGImage, imageFrame: CGRect, for snapshot: FieldSnapshot, options: ScreenContextOptions
    ) async throws -> String? {
        let chunks = try await WindowOCR.recognize(
            image: image, imageFrame: imageFrame, mask: snapshot.fieldFrame,
            languages: WindowOCR.recognitionLanguages(for: options.language)
        )
        return ScreenText.render(chunks, for: snapshot, maxCharacters: options.maxCharacters)
    }

    public static func prewarmOCR(languages: [String] = ["en"] + Locale.preferredLanguages) async {
        for configuration in OCRWarmUp.configurations(for: languages) {
            await OCRWarmUp.shared.start(configuration).value
        }
    }

    private func scanAndStore(_ snapshot: FieldSnapshot, _ options: ScreenContextOptions) async -> Entry {
        let key = snapshot.id
        let fieldText = snapshot.textBefore + snapshot.selectedText + snapshot.textAfter
        let scan = await AXWindowReader.scan(
            pid: snapshot.app.pid, caret: ScreenText.caretAnchor(snapshot),
            field: snapshot.fieldFrame, fieldText: fieldText
        )
        let axChunks = scan?.chunks ?? []
        let now = ContinuousClock.now
        let windowFrame = scan?.windowFrame ?? .zero
        let entry = Entry(
            axChunks: axChunks, window: WindowKey(pid: snapshot.app.pid, frame: windowFrame),
            windowFrame: windowFrame, fetchedAt: now
        )
        let axCharacters = characters(axChunks)
        summary = scan.map {
            "ax: \($0.nodesVisited) nodes, \(String(format: "%.1f", $0.elapsedMs)) ms, \(axChunks.count) chunks, "
                + "\(axCharacters) chars\($0.hitBudget ? ", budget hit" : "")"
        } ?? "ax: no focused window"
        logger.info("\(self.summary ?? "", privacy: .public)")

        let retryDue = ocrBackoff[entry.window].map { now >= $0.retryAt } ?? true
            && ocrDeclinedUntil.map { now >= $0 } ?? true
        if options.allowOCR, axCharacters < options.ocrBelowAXCharacters, retryDue,
           windowReads.allowsRead(of: entry.window, at: now), ScreenRecordingPermission.isGranted {
            startOCR(snapshot, entry: entry, language: options.language, at: now)
        }

        cache = cache.filter { now - $0.value.fetchedAt < Self.entryLifetime }
        ocrBackoff = ocrBackoff.filter { now - $0.value.retryAt < Self.entryLifetime }
        cache[key] = entry
        scans[key] = nil
        return entry
    }

    private func startOCR(_ snapshot: FieldSnapshot, entry: Entry, language: String?, at now: ContinuousClock.Instant) {
        let languages = WindowOCR.recognitionLanguages(for: language)
        guard OCRWarmUp.shared.isReady(languages) else {
            _ = OCRWarmUp.shared.start(languages)
            return note("ocr skipped: models loading")
        }
        switch ocrSlot.claim(at: now) {
        case .busy:
            return note("ocr skipped: another OCR is running")
        case .takenFromStuck:
            note("ocr: the last OCR has not returned after \(OCRSlot.stuckAfter.components.seconds) s", level: .error)
        case .granted:
            break
        }
        let window = entry.window, windowFrame = entry.windowFrame
        let task = Task {
            let chunks = await runOCR(
                snapshot, window: window, windowFrame: windowFrame, languages: languages, claim: now
            )
            if pendingOCR[window]?.claim == now { pendingOCR[window] = nil }
            guard let chunks else { return }
            windowReads.store(chunks, of: window, at: .now)
        }
        pendingOCR[window] = (now, task)
    }

    /// A capture still running at the timeout is left to finish on its own and its result is dropped; no other
    /// OCR starts until it returns.
    private func runOCR(
        _ snapshot: FieldSnapshot, window: WindowKey, windowFrame: CGRect, languages: [Locale.Language]?,
        claim: ContinuousClock.Instant
    ) async -> [TextChunk]? {
        let pid = snapshot.app.pid, mask = snapshot.fieldFrame, caret = ScreenText.caretAnchor(snapshot)
        let clock = ContinuousClock()
        let start = clock.now
        let recognition = Task { () -> Result<[TextChunk], any Error> in
            do {
                return .success(try await WindowOCR.recognize(
                    pid: pid, windowFrame: windowFrame, mask: mask, caret: caret, languages: languages
                ))
            } catch {
                return .failure(error)
            }
        }
        Task {
            _ = await recognition.value
            ocrSlot.release(claim)
        }
        let result = await Deadline.run(within: Self.ocrTimeout) { await recognition.value }
        let elapsed = (clock.now - start).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        switch result {
        case .success(let chunks)?:
            ocrBackoff[window] = nil
            note("ocr: \(String(format: "%.0f", ms)) ms, \(characters(chunks)) chars")
            return chunks
        case .failure(let error)?:
            note("ocr failed: \(String(describing: error))", level: .error)
            if WindowOCR.isDeclined(error) { ocrDeclinedUntil = .now + Self.declinedPause }
        case nil:
            note("ocr: timed out", level: .error)
        }
        let failures = (ocrBackoff[window]?.failures ?? 0) + 1
        let delay = min(Self.entryLifetime, .seconds(1 << min(failures, 6)))
        ocrBackoff[window] = OCRBackoff(failures: failures, retryAt: .now + delay)
        return nil
    }

    /// Appends to the scan summary and logs it. Counts and errors only, never screen text.
    private func note(_ part: String, level: OSLogType = .info) {
        summary = (summary ?? "") + "; " + part
        logger.log(level: level, "\(part, privacy: .public)")
    }
}

struct WindowKey: Hashable {
    var pid: pid_t
    var x, y, width, height: Int

    init(pid: pid_t, frame: CGRect) {
        self.pid = pid
        x = Int(frame.minX.rounded())
        y = Int(frame.minY.rounded())
        width = Int(frame.width.rounded())
        height = Int(frame.height.rounded())
    }
}

/// OCR results by window, shared by the window's fields. A window is read at most once per `rereadAfter`:
/// each capture shows the screen-recording indicator and recognition takes a few hundred milliseconds.
struct WindowReads {
    static let rereadAfter: Duration = .seconds(30)
    static let lifetime: Duration = .seconds(60)

    private var reads: [WindowKey: (chunks: [TextChunk], at: ContinuousClock.Instant)] = [:]

    func chunks(of window: WindowKey, outside field: CGRect, at now: ContinuousClock.Instant) -> [TextChunk]? {
        guard let read = reads[window], now - read.at < Self.lifetime else { return nil }
        guard !field.isEmpty else { return read.chunks }
        return read.chunks.filter { !$0.frame.intersects(field) }
    }

    func allowsRead(of window: WindowKey, at now: ContinuousClock.Instant) -> Bool {
        guard let read = reads[window] else { return true }
        return now - read.at >= Self.rereadAfter
    }

    mutating func store(_ chunks: [TextChunk], of window: WindowKey, at now: ContinuousClock.Instant) {
        reads = reads.filter { now - $0.value.at < Self.lifetime }
        reads[window] = (chunks, now)
    }
}

/// One OCR at a time. A recognition that has not returned after `stuckAfter`, longer than the 1-2.5 minute
/// model compile, no longer blocks the next one.
struct OCRSlot {
    static let stuckAfter: Duration = .seconds(180)

    enum Claim { case granted, busy, takenFromStuck }

    private var holder: ContinuousClock.Instant?

    mutating func claim(at now: ContinuousClock.Instant) -> Claim {
        guard let holder else {
            self.holder = now
            return .granted
        }
        guard now - holder >= Self.stuckAfter else { return .busy }
        self.holder = now
        return .takenFromStuck
    }

    mutating func release(_ claim: ContinuousClock.Instant) {
        if holder == claim { holder = nil }
    }
}

final class OCRWarmUp: Sendable {
    typealias Configuration = [Locale.Language]?

    static let shared = OCRWarmUp()

    private struct State {
        var tasks: [Configuration: Task<Void, Never>] = [:]
        var ready: Set<Configuration> = []
        var last: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let logger = Logger.gw("ScreenContext")

    static func configurations(
        for languages: [String], supported: [Locale.Language] = WindowOCR.supportedLanguages
    ) -> [Configuration] {
        var result: [Configuration] = [nil]
        for language in languages {
            let configuration = WindowOCR.recognitionLanguages(for: language, supported: supported)
            if !result.contains(configuration) { result.append(configuration) }
        }
        return result
    }

    func isReady(_ configuration: Configuration) -> Bool {
        state.withLock { $0.ready.contains(configuration) }
    }

    func start(_ configuration: Configuration) -> Task<Void, Never> {
        state.withLock { state in
            if let task = state.tasks[configuration] { return task }
            let previous = state.last
            let name = configuration.map { $0.map(\.minimalIdentifier).joined(separator: "+") } ?? "automatic"
            let task = Task.detached(priority: .utility) { [self] in
                await previous?.value
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    try await WindowOCR.prewarm(languages: configuration)
                    self.state.withLock { _ = $0.ready.insert(configuration) }
                    let seconds = (clock.now - start).components.seconds
                    self.logger.info("OCR models ready (\(name, privacy: .public)) after \(seconds, privacy: .public) s")
                } catch {
                    self.state.withLock { $0.tasks[configuration] = nil }
                    self.logger.error(
                        "OCR prewarm (\(name, privacy: .public)) failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            state.tasks[configuration] = task
            state.last = task
            return task
        }
    }
}

private func characters(_ chunks: [TextChunk]) -> Int {
    chunks.reduce(0) { $0 + $1.text.count }
}

public enum ScreenRecordingPermission {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    public static func request() {
        _ = CGRequestScreenCaptureAccess()
    }

    // True once the user has turned Ghostwriter on under Screen Recording, also before the relaunch that
    // `isGranted` waits for: macOS shows other apps' window titles only to apps with the permission.
    public static var isAllowedInSettings: Bool {
        if isGranted { return true }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let owner = window[kCGWindowOwnerName as String] as? String, owner != "Window Server", owner != "Dock",
                  let name = window[kCGWindowName as String] as? String
            else { return false }
            return !name.isEmpty
        }
    }

    /// Captures a few points of one of Ghostwriter's own windows and discards them. macOS asks the user to confirm
    /// screen capture on an app's first capture after the grant; doing it while onboarding or settings is open
    /// shows that prompt there instead of over the user's writing later. True when the capture ran.
    @discardableResult
    public static func confirmWithSystem() async -> Bool {
        guard isGranted else { return false }
        do {
            let captured = try await WindowOCR.captureOwnWindowSample()
            logger.info("Screen capture confirmation: \(captured ? "captured" : "no window on screen", privacy: .public)")
            return captured
        } catch {
            logger.error("Screen capture confirmation failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static let logger = Logger.gw("ScreenContext")
}

