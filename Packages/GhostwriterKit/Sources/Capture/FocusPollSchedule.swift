/// How often the focus poll reads the field. The poll backs up the Accessibility notifications and the reads
/// after each key press, so it slows down once nothing has happened for a while and stops while nobody is at the Mac.
struct FocusPollSchedule {
    static let activeInterval: Duration = .seconds(1)
    static let quietInterval: Duration = .seconds(4)
    static let quietAfter: Duration = .seconds(30)

    private var lastActivity: ContinuousClock.Instant
    var isAway = false

    init(now: ContinuousClock.Instant) {
        lastActivity = now
    }

    mutating func noteActivity(at now: ContinuousClock.Instant) {
        lastActivity = now
    }

    /// Nil while nobody is at the Mac: the poll stops.
    func interval(at now: ContinuousClock.Instant) -> Duration? {
        guard !isAway else { return nil }
        return now - lastActivity < Self.quietAfter ? Self.activeInterval : Self.quietInterval
    }
}
