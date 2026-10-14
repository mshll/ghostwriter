import AppKit
import ApplicationServices
import GWCore
import os

@MainActor
public final class FocusTracker {
    public var onEvent: ((FocusEvent) -> Void)?
    /// Called with a bundle ID, and with `domain:<host>` (lowercased, `www.` stripped) for web fields.
    public var ruleProvider: ((String) -> AppRule?)?
    public var onDiagnostics: ((ReadDiagnostics) -> Void)?
    public var includesOwnApp = false {
        didSet {
            guard includesOwnApp != oldValue, isRunning else { return }
            tearDownObservation()
            retarget(to: Self.appTarget(NSWorkspace.shared.frontmostApplication))
        }
    }

    private struct Unfocused: Equatable {
        var app: AppIdentity?
        var reason: IneligibleReason
    }

    private static let log = Logger.gw("capture")
    private static let debounce: TimeInterval = 0.005
    private static let terminalDebounce: TimeInterval = 0.030
    private static let pollInterval: TimeInterval = 1.0
    private static let treePollInterval: Duration = .milliseconds(150)
    private static let treePollDuration: Duration = .seconds(4)
    private static let transientRetryDelay: TimeInterval = 0.05

    private let worker = CaptureWorker()
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var isRunning = false
    private var target: AppTarget?
    private var observation: Observation?
    private var current: FieldSnapshot?
    private var lastUnfocused: Unfocused?
    private var readScheduled = false
    private var readInFlight = false
    private var rereadRequested = false
    private var transientStrikes = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var treePoll: (app: AppTarget?, until: ContinuousClock.Instant, task: Task<Void, Never>)?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
                [weak self] note in
                let app = Self.appTarget(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                MainActor.assumeIsolated { self?.retarget(to: app) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
                [weak self] note in
                let app = Self.appTarget(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                MainActor.assumeIsolated { self?.appTerminated(app) }
            },
        ]
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestRead() }
        }
        retarget(to: Self.appTarget(NSWorkspace.shared.frontmostApplication))
    }

    /// Leaves the web accessibility flags written to other apps on: turning them off would remove the web tree
    /// for every assistive app.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        pollTimer?.invalidate()
        pollTimer = nil
        treePoll?.task.cancel()
        treePoll = nil
        tearDownObservation()
        target = nil
        current = nil
        lastUnfocused = nil
        Task { await worker.detach() }
    }

    public func snapshot() async -> FieldSnapshot? {
        guard let app = target ?? Self.appTarget(NSWorkspace.shared.frontmostApplication),
              !isExcluded(app) else { return nil }
        let outcome = await worker.read(app, rule: rule(for: app.identity.bundleID))
        onDiagnostics?(outcome.diagnostics)
        guard case .field(let snapshot) = outcome.result, siteReason(snapshot) == nil else { return nil }
        return snapshot
    }

    fileprivate func accessibilityNotification() {
        requestRead()
    }

    // MARK: Targeting

    private func retarget(to app: AppTarget?) {
        guard isRunning, app != target || observation == nil else { return }
        tearDownObservation()
        target = app
        guard let app else {
            publishUnfocused(nil, .noFocusedElement)
            Task { await worker.detach() }
            return
        }
        if isExcluded(app) {
            publishUnfocused(app.identity, .ownApp)
            Task { await worker.detach() }
            return
        }
        let observation = Observation(tracker: self, pid: app.identity.pid)
        self.observation = observation
        let registration = observation?.registration
        let rule = rule(for: app.identity.bundleID)
        Task {
            let wroteFlags = await worker.attach(app, rule: rule, registration: registration)
            requestRead()
            if wroteFlags { pollUntilField() }
        }
    }

    private func isExcluded(_ app: AppTarget) -> Bool {
        app.identity.pid == ownPID && !includesOwnApp
    }

    private func appTerminated(_ app: AppTarget?) {
        guard let app else { return }
        Task { await worker.forget(app.identity.pid) }
        if app.identity.pid == target?.identity.pid {
            target = nil
            retarget(to: Self.appTarget(NSWorkspace.shared.frontmostApplication))
        }
    }

    private func tearDownObservation() {
        guard let observation else { return }
        self.observation = nil
        observation.removeFromRunLoop()
        // Released on a later turn: this may run inside the observer's own callback.
        DispatchQueue.main.async { withExtendedLifetime(observation) {} }
    }

    // MARK: Reading

    private func requestRead() {
        guard isRunning, !readScheduled else { return }
        readScheduled = true
        let isTerminal = target.map { BuiltInAppRules.isTerminal($0.identity.bundleID) } ?? false
        let delay = isTerminal ? Self.terminalDebounce : Self.debounce
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.performRead() }
        }
    }

    private func performRead() {
        readScheduled = false
        guard isRunning, let app = target, !isExcluded(app) else { return }
        guard !readInFlight else {
            rereadRequested = true
            return
        }
        readInFlight = true
        let rule = rule(for: app.identity.bundleID)
        Task {
            let outcome = await worker.read(app, rule: rule)
            readInFlight = false
            apply(outcome, for: app)
            if rereadRequested {
                rereadRequested = false
                requestRead()
            }
        }
    }

    /// The web tree appears up to about 2 s after the flags are written: read often until a field shows up.
    private func pollUntilField() {
        let now = ContinuousClock.now
        if let treePoll, treePoll.app == target, now < treePoll.until { return }
        treePoll?.task.cancel()
        let app = target, until = now + Self.treePollDuration
        let task = Task { [weak self] in
            while ContinuousClock.now < until {
                do {
                    try await Task.sleep(for: Self.treePollInterval)
                } catch {
                    return
                }
                guard let self, self.isRunning, self.target == app, self.current == nil else { return }
                self.requestRead()
            }
        }
        treePoll = (app, until, task)
    }

    private func apply(_ outcome: ReadOutcome, for app: AppTarget) {
        var diagnostics = outcome.diagnostics
        var result = outcome.result
        if case .field(let snapshot) = result, let reason = siteReason(snapshot) {
            result = .ineligible(reason)
            diagnostics.reason = reason
        }
        onDiagnostics?(diagnostics)
        guard isRunning, app == target else { return }
        if outcome.retrySoon { pollUntilField() }
        if let strikesAllowed = transientStrikesAllowed(result) {
            transientStrikes += 1
            if transientStrikes < strikesAllowed {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.transientRetryDelay) { [weak self] in
                    MainActor.assumeIsolated { self?.requestRead() }
                }
                return
            }
        } else {
            transientStrikes = 0
        }
        switch result {
        case .field(let snapshot): publishField(snapshot)
        case .ineligible(let reason): publishUnfocused(app.identity, reason)
        case .timedOut: publishUnfocused(app.identity, .unreadable)
        }
    }

    /// Results that often last one read only: an app busy past the timeout, or focus between two elements.
    /// Confirm them with quick re-reads before giving up the current field.
    private func transientStrikesAllowed(_ result: ReadResult) -> Int? {
        switch result {
        case .timedOut: 3
        case .ineligible(.noFocusedElement) where current != nil: 2
        default: nil
        }
    }

    private func publishField(_ snapshot: FieldSnapshot) {
        let previous = current
        current = snapshot
        lastUnfocused = nil
        if previous?.id != snapshot.id {
            onEvent?(.focused(snapshot))
        } else if previous != snapshot {
            onEvent?(.changed(snapshot))
        }
    }

    private func publishUnfocused(_ app: AppIdentity?, _ reason: IneligibleReason) {
        let state = Unfocused(app: app, reason: reason)
        guard current != nil || lastUnfocused != state else { return }
        current = nil
        lastUnfocused = state
        onEvent?(.unfocused(app, reason))
    }

    // MARK: Rules

    private func rule(for bundleID: String) -> AppRule {
        (BuiltInAppRules.rule(for: bundleID) ?? AppRule(bundleID: bundleID)).merged(with: ruleProvider?(bundleID))
    }

    private func siteReason(_ snapshot: FieldSnapshot) -> IneligibleReason? {
        guard let url = snapshot.url, url.scheme == "http" || url.scheme == "https",
              let host = url.host().map(DomainPattern.normalize) else { return nil }
        let key = "domain:\(host)"
        let rule = (BuiltInAppRules.domainRule(forHost: host) ?? AppRule(bundleID: key)).merged(with: ruleProvider?(key))
        return rule.completionsEnabled == false ? .excludedSite : nil
    }

    private nonisolated static func appTarget(_ app: NSRunningApplication?) -> AppTarget? {
        guard let app else { return nil }
        return AppTarget(
            identity: AppIdentity(
                bundleID: app.bundleIdentifier ?? "",
                name: app.localizedName ?? "",
                pid: app.processIdentifier
            ),
            bundleURL: app.bundleURL
        )
    }
}

@MainActor
private final class Observation {
    private static let log = Logger.gw("capture")

    private let observer: AXObserver
    private let source: CFRunLoopSource
    private let box: ObserverBox
    let registration: ObserverRegistration

    init?(tracker: FocusTracker, pid: pid_t) {
        var created: AXObserver?
        let error = AXObserverCreate(pid, observerCallback, &created)
        guard error == .success, let created else {
            Self.log.error("AXObserverCreate failed for pid \(pid): \(error.rawValue)")
            return nil
        }
        observer = created
        box = ObserverBox(tracker: tracker)
        source = AXObserverGetRunLoopSource(created)
        registration = ObserverRegistration(
            pid: pid, observer: created, refcon: Unmanaged.passUnretained(box).toOpaque()
        )
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func removeFromRunLoop() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
}

@MainActor
private final class ObserverBox {
    weak var tracker: FocusTracker?

    init(tracker: FocusTracker) {
        self.tracker = tracker
    }
}

private func observerCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let box = UInt(bitPattern: refcon)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: box) else { return }
        Unmanaged<ObserverBox>.fromOpaque(pointer).takeUnretainedValue().tracker?.accessibilityNotification()
    }
}
