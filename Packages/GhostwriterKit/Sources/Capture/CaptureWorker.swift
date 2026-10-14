import ApplicationServices
import Foundation
import GWCore
import os

struct ReadOutcome: Sendable {
    var pid: pid_t
    var result: ReadResult
    var diagnostics: ReadDiagnostics
    var retrySoon: Bool
}

struct ObserverRegistration: @unchecked Sendable {
    let pid: pid_t
    let observer: AXObserver
    let refcon: UnsafeMutableRawPointer
}

actor CaptureWorker {
    private static let log = Logger.gw("capture")
    private static let appNotifications = [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification]
    private static let fieldNotifications = [
        kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXUIElementDestroyedNotification,
    ]

    private enum Engine { case electron, chromium, other }

    private let queue = DispatchSerialQueue(label: "com.mshl.ghostwriter.capture")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var registration: ObserverRegistration?
    private var observedField: AXElement?
    private var context: FieldContext?
    private var engines: [pid_t: Engine] = [:]
    private var rolesRead: Set<pid_t> = []
    private var flagWrites: [WebAccessibility.Flag: ContinuousClock.Instant] = [:]
    private var enhancedFallback = EnhancedUserInterfaceFallback()
    private var preparationRetry: PreparationRetry?
    private let calibration = CaretCalibration()

    func attach(_ app: AppTarget, rule: AppRule, registration: ObserverRegistration?) -> Bool {
        detach()
        let appElement = AXElement.application(app.identity.pid)
        let excluded = Self.isExcluded(app, rule: rule)
        var (wroteFlags, pending) = excluded
            ? (false, []) : prepare(app, rule: rule, appElement: appElement, steps: PreparationStep.webContent)
        enhancedFallback.arm(
            pid: app.identity.pid, at: .now,
            allowed: !excluded && engine(of: app) != .other && rule.needsEnhancedUserInterface != true
        )
        self.registration = registration
        if let registration, !addAppNotifications(appElement, registration) {
            pending.insert(.appNotifications)
        }
        guard !pending.isEmpty else { return wroteFlags }
        preparationRetry = PreparationRetry(pid: app.identity.pid, steps: pending, at: .now)
        Self.log.info("\(app.identity.bundleID, privacy: .public) did not answer yet; retrying \(pending.count) steps")
        return true
    }

    func detach() {
        unobserveField()
        registration = nil
        context = nil
        preparationRetry = nil
    }

    func forget(_ pid: pid_t) {
        engines[pid] = nil
        rolesRead.remove(pid)
        flagWrites = flagWrites.filter { $0.key.pid != pid }
        if preparationRetry?.pid == pid { preparationRetry = nil }
    }

    func read(_ app: AppTarget, rule: AppRule) -> ReadOutcome {
        let started = ContinuousClock.now
        var diagnostics = ReadDiagnostics(
            bundleID: app.identity.bundleID, duration: .zero, textPath: .none, caretSource: .none, reason: nil
        )
        var retrySoon = false
        let result: ReadResult
        if SecureInput.isEnabled {
            result = .ineligible(.secureInputActive)
        } else if Self.isExcluded(app, rule: rule) {
            result = .ineligible(.excludedApp)
        } else {
            let preparing = retryPreparation(app, rule: rule)
            do {
                (result, retrySoon) = try readFocused(app, rule: rule, diagnostics: &diagnostics)
                retrySoon = retrySoon || preparing
            } catch {
                retrySoon = preparing
                Self.log.debug("AX read failed in \(app.identity.bundleID, privacy: .public): \(error.code.rawValue)")
                if error.code == .cannotComplete {
                    result = .timedOut
                } else {
                    context = nil
                    result = .ineligible(.noFocusedElement)
                }
            }
        }
        diagnostics.duration = ContinuousClock.now - started
        diagnostics.reason = result.reason
        return ReadOutcome(pid: app.identity.pid, result: result, diagnostics: diagnostics, retrySoon: retrySoon)
    }

    private func readFocused(
        _ app: AppTarget, rule: AppRule, diagnostics: inout ReadDiagnostics
    ) throws(AXFailure) -> (ReadResult, Bool) {
        let appElement = AXElement.application(app.identity.pid)
        guard let focused = try appElement.element(kAXFocusedUIElementAttribute) else {
            let wroteEnhanced = enhancedFallback.take(pid: app.identity.pid, at: .now)
                && enableEnhancedUserInterface(app, appElement) == .done
            context = nil
            unobserveField()
            return (.ineligible(.noFocusedElement), wroteEnhanced)
        }

        let reader = FieldReader(app: app, rule: rule, calibration: calibration)
        let fieldContext: FieldContext
        if let context, context.element == focused, context.rule == rule {
            fieldContext = context
        } else {
            fieldContext = try reader.context(for: focused)
            context = fieldContext
            if fieldContext.verdict == nil { observeField(focused) } else { unobserveField() }
        }
        if let verdict = fieldContext.verdict { return (.ineligible(verdict), false) }
        return (try reader.read(fieldContext, diagnostics: &diagnostics), false)
    }

    private static func isExcluded(_ app: AppTarget, rule: AppRule) -> Bool {
        AppCatalog.passwordManagers.contains(app.identity.bundleID) || rule.completionsEnabled == false
    }

    /// Exposes web content in Electron and Chromium apps, on each activation. Reading the app's role turns on a
    /// basic web tree within about 0.1 s and is done once per process. Electron's flag adds the full tree after a
    /// 2 s delay and is written again on each activation because another assistive app may have turned it off.
    /// `AXEnhancedUserInterface` changes how the app animates windows, so it is written only where the app rule
    /// asks for it, or once per activation when the role read brought up no focused element.
    private func prepare(
        _ app: AppTarget, rule: AppRule, appElement: AXElement, steps: Set<PreparationStep>
    ) -> (wrote: Bool, pending: Set<PreparationStep>) {
        let pid = app.identity.pid
        let engine = engine(of: app)
        var outcomes: [PreparationStep: StepOutcome] = [:]
        if steps.contains(.readRole), engine != .other, !rolesRead.contains(pid) {
            outcomes[.readRole] = readRole(app, appElement)
            if outcomes[.readRole] == .done { rolesRead.insert(pid) }
        }
        if steps.contains(.manualAccessibility), engine == .electron {
            outcomes[.manualAccessibility] = enable(AXName.manualAccessibility, in: app, appElement)
        }
        if steps.contains(.enhancedUserInterface), rule.needsEnhancedUserInterface == true {
            outcomes[.enhancedUserInterface] = enableEnhancedUserInterface(app, appElement)
        }
        return (outcomes.values.contains(.done), Set(outcomes.filter { $0.value == .notReady }.keys))
    }

    private func retryPreparation(_ app: AppTarget, rule: AppRule) -> Bool {
        guard var retry = preparationRetry, retry.pid == app.identity.pid else { return false }
        let now = ContinuousClock.now
        if retry.isExpired(at: now) {
            preparationRetry = nil
            Self.log.info("\(app.identity.bundleID, privacy: .public) still did not answer; waiting for its next activation")
            return false
        }
        guard retry.isDue(at: now) else { return true }
        let appElement = AXElement.application(app.identity.pid)
        var (_, pending) = prepare(app, rule: rule, appElement: appElement, steps: retry.steps)
        if retry.steps.contains(.appNotifications), let registration, !addAppNotifications(appElement, registration) {
            pending.insert(.appNotifications)
        }
        guard !pending.isEmpty else {
            preparationRetry = nil
            Self.log.info("\(app.identity.bundleID, privacy: .public) answered on retry \(retry.attempts + 1)")
            return true
        }
        retry.failed(pending, at: now)
        preparationRetry = retry
        return true
    }

    private func engine(of app: AppTarget) -> Engine {
        if let engine = engines[app.identity.pid] { return engine }
        let engine = Self.engine(of: app.bundleURL)
        engines[app.identity.pid] = engine
        return engine
    }

    private func readRole(_ app: AppTarget, _ appElement: AXElement) -> StepOutcome {
        do {
            _ = try appElement.value(kAXRoleAttribute)
            return .done
        } catch {
            Self.log.debug("Reading the role of \(app.identity.bundleID, privacy: .public) failed: \(error.code.rawValue)")
            return error.code == .cannotComplete ? .notReady : .failed
        }
    }

    private func enableEnhancedUserInterface(_ app: AppTarget, _ appElement: AXElement) -> StepOutcome {
        guard !AppCatalog.enhancedUserInterfaceBlocked.contains(app.identity.bundleID) else { return .skipped }
        return enable(AXName.enhancedUserInterface, in: app, appElement)
    }

    /// Never writes false: that tears the web tree down for every assistive app. A write the app did not answer
    /// does not count, so a retry can make it.
    private func enable(_ attribute: String, in app: AppTarget, _ appElement: AXElement) -> StepOutcome {
        let flag = WebAccessibility.Flag(pid: app.identity.pid, attribute: attribute)
        let now = ContinuousClock.now
        guard WebAccessibility.isDue(lastWrite: flagWrites[flag], now: now) else { return .skipped }
        let error = appElement.set(attribute, NSNumber(value: true))
        if error == .cannotComplete {
            Self.log.info("\(attribute, privacy: .public) on \(app.identity.bundleID, privacy: .public): no answer yet")
            return .notReady
        }
        flagWrites[flag] = now
        let written = WebAccessibility.isWritten(error, attribute: attribute) {
            do throws(AXFailure) {
                return AXDecode.bool(try appElement.value(attribute))
            } catch {
                Self.log.debug("Reading back \(attribute, privacy: .public) failed: \(error.code.rawValue)")
                return nil
            }
        }
        Self.log.info(
            "\(attribute, privacy: .public) on \(app.identity.bundleID, privacy: .public): \(error.rawValue), written \(written)"
        )
        return written ? .done : .failed
    }

    private static func engine(of bundleURL: URL?) -> Engine {
        guard let frameworks = bundleURL?.appending(path: "Contents/Frameworks", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: frameworks.path) else { return .other }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: frameworks.path)
        } catch {
            log.debug("Cannot list frameworks: \(error.localizedDescription, privacy: .public)")
            return .other
        }
        if names.contains("Electron Framework.framework") { return .electron }
        let isChromium = names.contains {
            $0.hasSuffix(" Framework.framework") && $0 != "Chromium Embedded Framework.framework"
        }
        return isChromium ? .chromium : .other
    }

    private func observeField(_ element: AXElement) {
        guard observedField != element else { return }
        unobserveField()
        guard let registration, element.pid == registration.pid else { return }
        for name in Self.fieldNotifications {
            add(name, to: element, registration)
        }
        observedField = element
    }

    private func unobserveField() {
        guard let field = observedField else { return }
        observedField = nil
        guard let registration else { return }
        for name in Self.fieldNotifications {
            let error = AXObserverRemoveNotification(registration.observer, field.ref, name as CFString)
            if error != .success {
                Self.log.debug("AXObserverRemoveNotification \(name, privacy: .public): \(error.rawValue)")
            }
        }
    }

    private func addAppNotifications(_ appElement: AXElement, _ registration: ObserverRegistration) -> Bool {
        Self.appNotifications.map { add($0, to: appElement, registration) }.allSatisfy { $0 != .cannotComplete }
    }

    @discardableResult
    private func add(_ name: String, to element: AXElement, _ registration: ObserverRegistration) -> AXError {
        let error = AXObserverAddNotification(registration.observer, element.ref, name as CFString, registration.refcon)
        if error != .success, error != .notificationAlreadyRegistered {
            Self.log.debug("AXObserverAddNotification \(name, privacy: .public): \(error.rawValue)")
        }
        return error
    }
}

enum PreparationStep: Hashable, Sendable {
    case readRole, manualAccessibility, enhancedUserInterface, appNotifications

    static let webContent: Set<PreparationStep> = [.readRole, .manualAccessibility, .enhancedUserInterface]
}

enum StepOutcome: Equatable {
    case done, skipped, failed
    case notReady
}

struct PreparationRetry {
    static let firstDelay: Duration = .milliseconds(250)
    static let maxDelay: Duration = .seconds(2)
    static let limit: Duration = .seconds(10)

    let pid: pid_t
    private(set) var steps: Set<PreparationStep>
    private(set) var attempts = 0
    private let until: ContinuousClock.Instant
    private var next: ContinuousClock.Instant
    private var delay = Self.firstDelay

    init(pid: pid_t, steps: Set<PreparationStep>, at now: ContinuousClock.Instant) {
        self.pid = pid
        self.steps = steps
        until = now + Self.limit
        next = now + Self.firstDelay
    }

    func isExpired(at now: ContinuousClock.Instant) -> Bool { now >= until }

    func isDue(at now: ContinuousClock.Instant) -> Bool { now >= next }

    mutating func failed(_ steps: Set<PreparationStep>, at now: ContinuousClock.Instant) {
        self.steps = steps
        attempts += 1
        delay = min(delay * 2, Self.maxDelay)
        next = now + delay
    }
}

struct EnhancedUserInterfaceFallback {
    /// Time for the role read to bring up the web tree, measured at 0.1 s.
    static let settle: Duration = .milliseconds(500)

    private var armed: (pid: pid_t, from: ContinuousClock.Instant)?

    mutating func arm(pid: pid_t, at now: ContinuousClock.Instant, allowed: Bool) {
        armed = allowed ? (pid, now + Self.settle) : nil
    }

    mutating func take(pid: pid_t, at now: ContinuousClock.Instant) -> Bool {
        guard let armed, armed.pid == pid, now >= armed.from else { return false }
        self.armed = nil
        return true
    }
}

enum WebAccessibility {
    struct Flag: Hashable, Sendable {
        let pid: pid_t
        let attribute: String
    }

    /// Longer than the apps' 2 s delay before the tree appears, which a new write restarts.
    static let rewriteInterval: Duration = .milliseconds(2500)

    static func isDue(lastWrite: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        guard let lastWrite else { return true }
        return now - lastWrite >= rewriteInterval
    }

    /// Chromium answers an `AXEnhancedUserInterface` write with `notImplemented` yet stores the flag and builds
    /// the tree, so that error counts as written when the flag reads back true.
    static func isWritten(_ error: AXError, attribute: String, readBack: () -> Bool?) -> Bool {
        if error == .success { return true }
        guard error == .notImplemented, attribute == AXName.enhancedUserInterface else { return false }
        return readBack() == true
    }
}
