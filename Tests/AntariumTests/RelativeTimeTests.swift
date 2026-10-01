import Foundation
import Testing
@testable import Antarium

/// The three relative-time strings a row can show.
///
/// They divide and truncate rather than round, which is right — truncation
/// cannot push a figure into a band it has not reached, so none of them can
/// print "60m" the way a rounding version would. What truncation does do is
/// produce nought, and only one of the three guarded against it.
@Suite("Relative times")
struct RelativeTimeTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> String {
        Format.age(now.addingTimeInterval(-seconds), now: now)
    }
    private func until(_ seconds: TimeInterval) -> String {
        Format.shortCountdown(to: now.addingTimeInterval(seconds), now: now)
    }

    // MARK: - How long ago

    @Test("Something very recent is just now")
    func recentIsJustNow() {
        #expect(ago(0) == "just now")
        #expect(ago(44) == "just now")
    }

    /// The gap this found. Between forty-five seconds and a minute the
    /// division truncates to nought, and "0 min ago" reads as a broken row
    /// rather than a recent one.
    @Test("Just under a minute is a minute, not nought", arguments: [45.0, 50.0, 59.0])
    func underAMinuteIsAMinute(_ seconds: TimeInterval) {
        #expect(ago(seconds) == "1 min ago",
                "\(seconds)s ago rendered as \(ago(seconds))")
    }

    @Test("Minutes and hours read as themselves")
    func minutesAndHours() {
        #expect(ago(60) == "1 min ago")
        #expect(ago(3_599) == "59 min ago")
        #expect(ago(3_600) == "1 h ago")
        #expect(ago(86_399) == "23 h ago")
        #expect(ago(86_400) == "1 d ago")
    }

    /// A timestamp in the future — a clock correction, a file touched by
    /// another machine — is not a negative age.
    @Test("A future timestamp is just now, not a negative age")
    func futureIsJustNow() {
        #expect(Format.age(now.addingTimeInterval(3_600), now: now) == "just now")
    }

    @Test("No timestamp says so")
    func absentIsNever() {
        #expect(Format.age(nil) == "never")
    }

    // MARK: - How long until

    /// The sibling that already guarded the nought case, which is how the
    /// gap above was noticed at all.
    @Test("Just under a minute away is a minute, not nought",
          arguments: [1.0, 30.0, 59.0])
    func countdownUnderAMinute(_ seconds: TimeInterval) {
        #expect(until(seconds) == "1m")
    }

    @Test("A countdown reads in the largest unit it fills")
    func countdownUnits() {
        #expect(until(2_820) == "47m")
        #expect(until(3_599) == "59m", "truncation must not print 60m")
        #expect(until(3_600) == "1h")
        #expect(until(86_399) == "23h")
        #expect(until(86_400) == "1d")
    }

    @Test("A moment already past is now")
    func pastIsNow() {
        #expect(until(0) == "now")
        #expect(until(-60) == "now")
    }

    @Test("No date is a dash")
    func absentCountdown() {
        #expect(Format.shortCountdown(to: nil) == "—")
    }

    // MARK: - The roomier phrasing

    @Test("A reset carries both parts, and drops an empty one")
    func longResetShape() {
        #expect(Format.longReset(now.addingTimeInterval(2_820), now: now)
            .hasPrefix("resets in 47m"))
        #expect(Format.longReset(now.addingTimeInterval(3_600), now: now)
            .hasPrefix("resets in 1h ·"), "an hour exactly should not say 1h 0m")
        #expect(Format.longReset(now.addingTimeInterval(4_320), now: now)
            .hasPrefix("resets in 1h 12m"))
        #expect(Format.longReset(now.addingTimeInterval(86_400), now: now)
            .hasPrefix("resets in 1d ·"))
        #expect(Format.longReset(now.addingTimeInterval(90_000), now: now)
            .hasPrefix("resets in 1d 1h"))
    }

    @Test("A reset that has arrived says so")
    func resetArrived() {
        #expect(Format.longReset(now, now: now) == "resetting now")
        #expect(Format.longReset(nil) == "no scheduled reset")
    }
}
