import GWCore
import Testing
@testable import Capture

@Suite struct FocusPollScheduleTests {
    private let start = ContinuousClock.now

    private func polls(in window: Duration, from schedule: FocusPollSchedule) -> Int {
        var now = start, count = 0
        while let interval = schedule.interval(at: now), now + interval <= start + window {
            now += interval
            count += 1
        }
        return count
    }

    @Test func pollsEverySecondAfterActivity() {
        let schedule = FocusPollSchedule(now: start)
        #expect(schedule.interval(at: start) == .seconds(1))
        #expect(schedule.interval(at: start + .seconds(29)) == .seconds(1))
    }

    @Test func slowsDownAfterAQuietSpell() {
        let schedule = FocusPollSchedule(now: start)
        #expect(schedule.interval(at: start + .seconds(30)) == .seconds(4))
        #expect(polls(in: .seconds(90), from: schedule) == 30 + 15)
    }

    @Test func activityBringsBackTheFastPoll() {
        var schedule = FocusPollSchedule(now: start)
        schedule.noteActivity(at: start + .seconds(60))
        #expect(schedule.interval(at: start + .seconds(61)) == .seconds(1))
    }

    @Test func stopsWhileAway() {
        var schedule = FocusPollSchedule(now: start)
        schedule.isAway = true
        #expect(schedule.interval(at: start) == nil)
        #expect(polls(in: .seconds(60), from: schedule) == 0)
    }
}

@Suite struct PresenceTests {
    private func presence(after events: [Presence.Event]) -> Presence {
        var presence = Presence()
        events.forEach { presence.apply($0) }
        return presence
    }

    @Test func awayWhileTheMacOrItsDisplaysSleepOrAnotherSessionIsInFront() {
        #expect(!Presence().isAway)
        #expect(presence(after: [.willSleep]).isAway)
        #expect(presence(after: [.screensDidSleep]).isAway)
        #expect(presence(after: [.sessionDidResignActive]).isAway)
    }

    @Test func backOnlyOnceEveryReasonIsGone() {
        #expect(presence(after: [.screensDidSleep, .sessionDidResignActive, .screensDidWake]).isAway)
        #expect(!presence(after: [.screensDidSleep, .sessionDidResignActive, .screensDidWake, .sessionDidBecomeActive]).isAway)
    }

    @Test func wakingFromSleepAlsoWakesTheDisplays() {
        #expect(!presence(after: [.screensDidSleep, .willSleep, .didWake]).isAway)
    }

    @Test func anAppComingToTheFrontMeansSomeoneIsThere() {
        #expect(!presence(after: [.willSleep, .screensDidSleep, .sessionDidResignActive, .appActivated]).isAway)
    }
}
