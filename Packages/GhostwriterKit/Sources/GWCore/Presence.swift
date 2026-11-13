import AppKit

/// Whether someone can be at the Mac: not while it sleeps, while its displays sleep, or while another user's
/// session is in front. An app coming to the front means someone is there, whatever came before.
public struct Presence: Sendable, Equatable {
    public enum Event: Sendable {
        case willSleep, didWake, screensDidSleep, screensDidWake, sessionDidResignActive, sessionDidBecomeActive, appActivated
    }

    private var asleep = false
    private var screensAsleep = false
    private var sessionInactive = false

    public init() {}

    public var isAway: Bool { asleep || screensAsleep || sessionInactive }

    public mutating func apply(_ event: Event) {
        switch event {
        case .willSleep: asleep = true
        case .didWake:
            asleep = false
            screensAsleep = false
        case .screensDidSleep: screensAsleep = true
        case .screensDidWake: screensAsleep = false
        case .sessionDidResignActive: sessionInactive = true
        case .sessionDidBecomeActive: sessionInactive = false
        case .appActivated: self = Presence()
        }
    }
}

/// Follows `Presence` through the workspace's sleep, display and session notifications.
@MainActor
public final class PresenceMonitor {
    public var onChange: ((_ isAway: Bool) -> Void)?
    public private(set) var presence = Presence()
    private var observers: [any NSObjectProtocol] = []

    private static let events: [(Notification.Name, Presence.Event)] = [
        (NSWorkspace.willSleepNotification, .willSleep),
        (NSWorkspace.didWakeNotification, .didWake),
        (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
        (NSWorkspace.screensDidWakeNotification, .screensDidWake),
        (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
        (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
        (NSWorkspace.didActivateApplicationNotification, .appActivated),
    ]

    public init() {}

    public func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = Self.events.map { name, event in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(event) }
            }
        }
    }

    public func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        presence = Presence()
    }

    private func apply(_ event: Presence.Event) {
        let wasAway = presence.isAway
        presence.apply(event)
        if presence.isAway != wasAway { onChange?(presence.isAway) }
    }
}
