import Foundation
import Testing
@testable import Antarium

/// What a looping agent's row says, as opposed to whether it is looping.
///
/// `isLooping` was covered; `describe` was not covered at all, and it is the
/// half a person reads. Every branch of it could be deleted without a test
/// objecting: the countdown, the switch from minutes to hours, the rounding,
/// and the refusal to describe a loop that is never going to wake.
@Suite("What a looping row says")
struct LoopWatchDescriptionTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func describe(in seconds: TimeInterval, stopped: Bool = false) -> String? {
        LoopWatch.describe(wakeAt: now.addingTimeInterval(seconds), stopped: stopped, now: now)
    }

    /// A live loop is always a little overdue — the agent is mid-iteration
    /// when we look — so being due is the ordinary case and reads as the
    /// plain fact rather than a countdown to a moment that has passed.
    @Test("A loop that is due or overdue just says it is looping",
          arguments: [30.0, 0.0, -1.0, -120.0, -3_599.0])
    func dueLoopsSayLooping(_ seconds: TimeInterval) {
        #expect(describe(in: seconds) == "looping")
    }

    @Test("A loop under an hour away counts down in minutes")
    func minutesAway() {
        #expect(describe(in: 720) == "loops in 12m")
        #expect(describe(in: 60) == "loops in 1m")
    }

    /// Rounded rather than truncated: ninety seconds is closer to two minutes
    /// than to one, and truncation turns anything under a minute into
    /// "loops in 0m".
    @Test("Minutes are rounded, not truncated")
    func minutesAreRounded() {
        #expect(describe(in: 90) == "loops in 2m")
        #expect(describe(in: 100) == "loops in 2m")
        #expect(describe(in: 31) == "loops in 1m",
                "just over the threshold truncated to nought minutes")
    }

    @Test("A loop an hour or more away counts down in hours")
    func hoursAway() {
        #expect(describe(in: 3_600) == "loops in 1h")
        #expect(describe(in: 7_200) == "loops in 2h")
    }

    /// The boundary between the two units, and the bug this test found: the
    /// unit was chosen before the rounding, so anything from 59½ minutes up
    /// read as "loops in 60m" — a number no clock shows.
    @Test("The switch to hours happens once the minutes would reach sixty")
    func unitBoundary() {
        #expect(describe(in: 3_540) == "loops in 59m")
        #expect(describe(in: 3_569) == "loops in 59m")
        #expect(describe(in: 3_570) == "loops in 1h", "59½ minutes read as 60m")
        #expect(describe(in: 3_599) == "loops in 1h")
        #expect(describe(in: 3_600) == "loops in 1h")
    }

    /// A session interrupted days ago still has a wakeup pending. Describing
    /// it would be a standing lie about an agent that will never move again.
    @Test("A loop long past its grace says nothing")
    func deadLoopSaysNothing() {
        #expect(describe(in: -LoopWatch.grace) == nil)
        #expect(describe(in: -3 * 86_400) == nil)
    }

    @Test("A stopped loop says nothing")
    func stoppedSaysNothing() {
        #expect(describe(in: 600, stopped: true) == nil)
    }

    @Test("An agent with no wakeup says nothing")
    func noWakeupSaysNothing() {
        #expect(LoopWatch.describe(wakeAt: nil, stopped: false, now: now) == nil)
    }

    /// A harness that states the fact in its own words is quoted rather than
    /// re-derived — and is believed even with no time to count down to, which
    /// is the case Codex's goal state is.
    @Test("A declared loop is reported in the harness's own words")
    func declaredWins() {
        #expect(LoopWatch.describe(declared: "goal running", wakeAt: nil,
                                   stopped: false, now: now) == "goal running")
        #expect(LoopWatch.describe(declared: "goal running",
                                   wakeAt: now.addingTimeInterval(600),
                                   stopped: false, now: now) == "goal running",
                "a declaration was overruled by a countdown")
    }

    /// The grace is an hour: long enough that a live loop mid-iteration is
    /// never called dead, short enough that yesterday's session is not called
    /// alive.
    @Test("The grace is an hour")
    func graceIsAnHour() {
        #expect(LoopWatch.grace == 3_600)
        #expect(LoopWatch.isLooping(wakeAt: now.addingTimeInterval(-3_599),
                                    stopped: false, now: now))
        #expect(LoopWatch.isLooping(wakeAt: now.addingTimeInterval(-3_600),
                                    stopped: false, now: now) == false)
    }
}
