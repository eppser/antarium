import Foundation
import Testing
@testable import Antarium

/// Every number on the bar goes through these. They are pure and they are
/// read constantly, and the rounding choices in them are decisions: a window
/// that resets in forty seconds says "1m" rather than "0m", because a
/// countdown that reads zero while still counting is worse than one that
/// rounds up.
@Suite("Numbers on the bar")
struct FormattingTests {

    // MARK: - Counts

    @Test("Counts stay exact below a thousand")
    func smallCounts() {
        #expect(Fmt.count(0) == "0")
        #expect(Fmt.count(7) == "7")
        #expect(Fmt.count(999) == "999")
    }

    @Test("Thousands and millions are abbreviated at their boundaries")
    func largeCounts() {
        #expect(Fmt.count(1_000) == "1.0k")
        #expect(Fmt.count(12_345) == "12.3k")
        #expect(Fmt.count(1_000_000) == "1.0M")
        #expect(Fmt.count(2_500_000) == "2.5M")
    }

    /// The machine this was written on has a German region, where a formatter
    /// that localises renders 10259 as "10.259" — which is how the bug this
    /// code exists to avoid was found. `String(format:)` and Swift's own
    /// interpolation are both POSIX; `NumberFormatter` is not.
    @Test("Counts do not pick up the reader's grouping separator")
    func countsAreNotLocalised() {
        // The dot in "10.3k" is a decimal point and belongs there; what must
        // not appear is a comma, which is what a localising formatter would
        // produce for the decimal under this region.
        #expect(Fmt.count(10_259) == "10.3k")
        #expect(!Fmt.count(10_259).contains(","), "a localised separator reached the bar")
        #expect(!Fmt.count(1_234_567).contains(","))
        // And the plain path returns only values below a thousand, which no
        // locale groups — so localising that branch is unobservable, and a
        // mutation of it cannot be caught. The abbreviated branch above is
        // where a separator could ever appear, and it is where the counts
        // this app shows actually land.
        #expect(Fmt.count(999) == "999")
    }

    // MARK: - Bytes

    @Test("Memory reads in megabytes until it needs gigabytes")
    func bytes() {
        #expect(Fmt.bytes(0) == "0MB")
        #expect(Fmt.bytes(52_428_800) == "50MB")
        #expect(Fmt.bytes(1_073_741_824) == "1.0GB")
        #expect(Fmt.bytes(3_221_225_472) == "3.0GB")
    }

    // MARK: - Durations

    /// A span under a minute still reads as a minute. Zero would say a window
    /// has reset when it has not.
    @Test("A span shorter than a minute rounds up rather than to zero")
    func shortDurations() {
        #expect(Fmt.duration(0) == "1m")
        #expect(Fmt.duration(40) == "1m")
        #expect(Fmt.duration(59) == "1m")
    }

    @Test("Durations step from minutes to hours to days")
    func durationSteps() {
        #expect(Fmt.duration(600) == "10m")
        #expect(Fmt.duration(3_600) == "1.0h")
        #expect(Fmt.duration(5_400) == "1.5h")
        #expect(Fmt.duration(86_400) == "1d")
        #expect(Fmt.duration(172_800) == "2d")
    }

    // MARK: - Countdowns

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A countdown with no reset time says so rather than guessing")
    func absentCountdown() {
        #expect(Format.shortCountdown(to: nil, now: now) == "—")
        #expect(Format.longReset(nil, now: now) == "no scheduled reset")
    }

    /// A reset in the past is now, not a negative number. The service has
    /// simply not told us it happened yet.
    @Test("A reset already due reads as now, never as a negative span")
    func pastCountdown() {
        let past = now.addingTimeInterval(-60)
        #expect(Format.shortCountdown(to: past, now: now) == "now")
        #expect(Format.longReset(past, now: now) == "resetting now")
        #expect(!Format.shortCountdown(to: past, now: now).contains("-"))
    }

    @Test("A countdown steps from minutes to hours to days")
    func countdownSteps() {
        func ahead(_ s: TimeInterval) -> String {
            Format.shortCountdown(to: now.addingTimeInterval(s), now: now)
        }
        #expect(ahead(30) == "1m")
        #expect(ahead(600) == "10m")
        #expect(ahead(7_200) == "2h")
        #expect(ahead(172_800) == "2d")
    }

    @Test("The roomier phrasing carries the remainder")
    func longResetSpans() {
        func ahead(_ s: TimeInterval) -> String { Format.longReset(now.addingTimeInterval(s), now: now) }
        #expect(ahead(5_400).hasPrefix("resets in 1h 30m · "))
        #expect(ahead(7_200).hasPrefix("resets in 2h · "), "a whole number of hours drops the minutes")
        #expect(ahead(90_000).hasPrefix("resets in 1d 1h · "))
        #expect(ahead(86_400).hasPrefix("resets in 1d · "))
    }
}
