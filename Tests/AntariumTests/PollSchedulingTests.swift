import Foundation
import Testing
@testable import Antarium

/// `resetsAt` is the one value in a usage response that decides when the app
/// *acts*, rather than what it shows. Everything else a server sends ends up
/// on screen; this ends up in a timer.
@Suite("A server cannot set the refresh rate")
@MainActor
struct PollSchedulingTests {

    private let interval: TimeInterval = 15 * 60

    private func gauge(_ id: String, used: Double, resetsAt: Date?) -> Gauge {
        Gauge(id: id, badge: "X", title: id, used: used,
              resetsAt: resetsAt, reportedSeverity: .normal)
    }

    @Test("With nothing reported, the user's interval stands")
    func plainInterval() {
        let now = Date()
        let next = AgentItem.nextPoll(after: now, interval: interval, resets: [])
        #expect(abs(next.timeIntervalSince(now) - interval) < 0.001)
    }

    @Test("A window rolling over sooner pulls the next look forward")
    func rolloverPullsForward() {
        let now = Date()
        let reset = now.addingTimeInterval(5 * 60)
        let next = AgentItem.nextPoll(after: now, interval: interval, resets: [reset])
        #expect(abs(next.timeIntervalSince(reset) - 20) < 0.001,
                "just after the rollover is the point of the whole mechanism")
    }

    @Test("A reset reported moments away cannot poll faster than the floor")
    func imminentResetIsFloored() {
        let now = Date()
        // What a hostile or broken endpoint would send on every reading.
        let next = AgentItem.nextPoll(after: now, interval: interval,
                                      resets: [now.addingTimeInterval(1)])
        #expect(next.timeIntervalSince(now) >= AgentItem.minimumPollInterval)
    }

    @Test("Neither can many of them at once")
    func manyImminentResets() {
        let now = Date()
        let resets = (0..<64).map { now.addingTimeInterval(Double($0) / 64) }
        let next = AgentItem.nextPoll(after: now, interval: interval, resets: resets)
        #expect(next.timeIntervalSince(now) >= AgentItem.minimumPollInterval)
    }

    @Test("A reset already past is ignored rather than polled immediately")
    func staleResetIgnored() {
        let now = Date()
        let next = AgentItem.nextPoll(after: now, interval: interval,
                                      resets: [now.addingTimeInterval(-86_400)])
        #expect(abs(next.timeIntervalSince(now) - interval) < 0.001)
    }

    @Test("A reset far beyond the interval never pushes the poll later")
    func distantResetDoesNotDelay() {
        let now = Date()
        let next = AgentItem.nextPoll(after: now, interval: interval,
                                      resets: [now.addingTimeInterval(86_400 * 365)])
        #expect(next.timeIntervalSince(now) <= interval + 0.001)
    }

    /// The floor must not be so large that it swallows the mechanism it is
    /// protecting — a real rollover minutes away still has to be honoured.
    @Test("The floor is below the rollover times it has to allow")
    func floorLeavesRoomForRealRollovers() {
        #expect(AgentItem.minimumPollInterval < 5 * 60)
    }

    @Test("Many windows crossing at once are one sound, not many")
    func soundsAreOnePerReading() {
        let now = Date()
        let before = (0..<64).map {
            gauge("w\($0)", used: 0.5, resetsAt: now)
        }
        let after = (0..<64).map {
            gauge("w\($0)", used: 0.99, resetsAt: now.addingTimeInterval(3600))
        }
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let crossed = AgentItem.crossings(from: previous, to: after)
        // Both conditions hold for all 64; the point is that the result is a
        // pair of flags rather than 64 plays.
        #expect(crossed.critical == (before[0].severity != .critical
                                     && after[0].severity == .critical))
        #expect(crossed.rolledOver == false, "headroom fell, so nothing rolled over")
    }

    @Test("A gauge with no previous reading makes no sound")
    func firstReadingIsSilent() {
        let crossed = AgentItem.crossings(from: [:], to: [gauge("w", used: 1, resetsAt: nil)])
        #expect(crossed.critical == false)
        #expect(crossed.rolledOver == false)
    }

    @Test("A window that actually rolled over is reported as such")
    func realRolloverIsNoticed() {
        let now = Date()
        let was = gauge("w", used: 0.95, resetsAt: now)
        let isNow = gauge("w", used: 0.1, resetsAt: now.addingTimeInterval(3600))
        let crossed = AgentItem.crossings(from: [was.id: was], to: [isNow])
        #expect(crossed.rolledOver, "reset moved later and headroom jumped back up")
    }
}

/// How often a failing provider is asked again. Too eager and the app
/// hammers a service that is already refusing it; too patient and a service
/// that has come back stays unnoticed until the user goes looking.
@Suite("Backing off from a failure")
@MainActor
struct FailureBackoffTests {

    private let interval: TimeInterval = 10 * 60

    /// A first failure is usually a dropped connection. Waiting the full
    /// interval to discover otherwise is worse than asking again shortly.
    @Test("The first retry comes sooner than the normal interval")
    func firstRetryIsProm() {
        #expect(AgentItem.backoff(failures: 1, interval: interval) == 120)
        #expect(AgentItem.backoff(failures: 1, interval: interval) < interval)
    }

    @Test("Each further failure waits longer than the last")
    func backoffGrows() {
        let waits = (1...4).map { AgentItem.backoff(failures: $0, interval: 3_600) }
        #expect(waits == [120, 240, 480, 960])
        #expect(waits == waits.sorted(), "the wait must not shrink as failures mount")
    }

    /// A failing provider must not end up checked *less* often than a
    /// working one, or a service that recovers is never noticed.
    @Test("The wait never exceeds the interval the user asked for")
    func neverSlowerThanConfigured() {
        for failures in 0...50 {
            #expect(AgentItem.backoff(failures: failures, interval: interval) <= interval)
        }
        #expect(AgentItem.backoff(failures: 99, interval: 60) == 60)
    }

    /// The doubling is capped before it is applied, so a long outage cannot
    /// turn into an overflow or an absurd wait.
    @Test("A very long outage does not overflow the wait")
    func longOutageIsBounded() {
        let wait = AgentItem.backoff(failures: Int.max, interval: 86_400)
        #expect(wait.isFinite)
        #expect(wait == 960, "the doubling is capped at four failures")
    }

    @Test("A count of zero or below is still a real wait")
    func nonPositiveFailures() {
        #expect(AgentItem.backoff(failures: 0, interval: interval) == 60)
        #expect(AgentItem.backoff(failures: -3, interval: interval) == 60)
    }
}
