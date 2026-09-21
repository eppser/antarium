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

/// The percentage beside a gauge, and how many gauges reach the bar at all.
/// Three mutations of this survived: both ends of the rounding, and the cap
/// on how many windows a provider may draw.
@Suite("Percentages do not round away their meaning")
@MainActor
struct GaugePercentTests {

    private func gauge(_ used: Double, amount: Gauge.Amount? = nil) -> Gauge {
        Gauge(id: "w", badge: "W", title: "Window", used: used,
              resetsAt: nil, reportedSeverity: .normal, amount: amount)
    }

    /// A window with a little used reads as a little, not as none. "0%"
    /// beside a window that has been used says the opposite of the truth.
    @Test("A fraction of a percent is not nothing")
    func smallIsNotZero() {
        #expect(Gauge.percentText(0.004) == "<1%")
        #expect(Gauge.percentText(0.0001) == "<1%")
        #expect(Gauge.percentText(0) == "0%", "nothing used is still nothing")
    }

    /// And a window nearly spent is not spent. "100%" beside a window with
    /// headroom left says the agent has stopped when it has not.
    @Test("A fraction short of the whole is not the whole")
    func nearlyFullIsNotFull() {
        #expect(Gauge.percentText(0.996) == ">99%")
        #expect(Gauge.percentText(0.9999) == ">99%")
        #expect(Gauge.percentText(1) == "100%", "actually spent reads as spent")
    }

    @Test("Ordinary percentages read as themselves")
    func ordinaryPercentages() {
        #expect(Gauge.percentText(0.5) == "50%")
        #expect(Gauge.percentText(0.25) == "25%")
    }

    /// Headroom is the complement of what is used, and the bar fills against
    /// it — reversing them turns a nearly-spent window into a nearly-empty
    /// one, which is the same picture with the opposite meaning.
    @Test("Headroom is what is left, not what is gone")
    func remainingIsTheComplement() {
        #expect(gauge(0.75).remaining == 0.25)
        #expect(gauge(0).remaining == 1)
        #expect(gauge(1).remaining == 0)
    }

    /// A balance has no denominator, so it has no meter and never colours
    /// itself urgent off a figure it does not have.
    @Test("A balance carries no meter and takes only the reported severity")
    func balanceHasNoMeter() {
        let balance = gauge(0, amount: Gauge.Amount(value: 5, currency: "USD"))
        #expect(!balance.hasMeter)
        #expect(balance.severity == .normal, "a balance coloured itself off a phantom fill")
        #expect(gauge(0.99).hasMeter)
    }

    /// The menu bar has room for two. A provider reporting four windows must
    /// not draw four bars across it.
    @Test("At most two windows reach the menu bar")
    func barIsCapped() {
        let many = (0..<6).map {
            Gauge(id: "w\($0)", badge: "W", title: "Window \($0)", used: 0.5,
                  resetsAt: nil, reportedSeverity: .normal)
        }
        let snapshot = Snapshot(providerID: "p", gauges: many, extras: [],
                                accountLabel: nil, fetchedAt: Date())
        #expect(StatusRender.rows(for: snapshot).count == 2)
        // And a provider with one window still draws one.
        let single = Snapshot(providerID: "p", gauges: [gauge(0.5)], extras: [],
                              accountLabel: nil, fetchedAt: Date())
        #expect(StatusRender.rows(for: single).count == 1)
    }
}

/// What the menu bar draws, which had one test for balances and nothing for
/// the rule the file states most plainly: the bar may fill or drain, and the
/// colour means the same thing either way.
@Suite("The menu bar says the same thing in both meter modes")
@MainActor
struct MeterModeTests {

    private func snapshot(_ used: Double, severity: Severity = .normal) -> Snapshot {
        Snapshot(providerID: "test",
                 gauges: [Gauge(id: "w", badge: "5H", title: "Session", used: used,
                                resetsAt: nil, reportedSeverity: severity)],
                 extras: [], accountLabel: nil, fetchedAt: Date())
    }

    /// The bar is the one thing that does follow the mode.
    @Test("The bar fills with what is used, or drains with what is left")
    func fillFollowsTheMode() {
        let s = snapshot(0.7)
        #expect(StatusRender.rows(for: s, mode: .used).first?.fill == 0.7)
        #expect(abs((StatusRender.rows(for: s, mode: .remaining).first?.fill ?? 0) - 0.3) < 0.0001)
    }

    @Test("The figure follows the mode with it")
    func percentFollowsTheMode() {
        let s = snapshot(0.7)
        #expect(StatusRender.rows(for: s, mode: .used).first?.percentText == "70%")
        #expect(StatusRender.rows(for: s, mode: .remaining).first?.percentText == "30%")
    }

    /// And the colour does not. Severity is headroom in both modes, so a
    /// nearly-spent quota is red whether the bar is nearly full or nearly
    /// empty. Tying the colour to the bar instead would paint a spent quota
    /// green for half the users — the same reading, the opposite warning.
    @Test("A nearly-spent quota is urgent in both modes",
          arguments: [0.0, 0.3, 0.5, 0.86, 0.95, 1.0])
    func severityIgnoresTheMode(used: Double) {
        let s = snapshot(used)
        let asUsed = StatusRender.rows(for: s, mode: .used).first
        let asRemaining = StatusRender.rows(for: s, mode: .remaining).first
        #expect(asUsed?.severity == asRemaining?.severity,
                Comment(rawValue: "at \(used) consumed the colour changed with the mode"))
    }

    /// Reachable in both directions, or the test above holds for a function
    /// that returns one colour for everything.
    @Test("The colour still moves with the reading")
    func severityIsNotConstant() {
        let calm = StatusRender.rows(for: snapshot(0.1), mode: .used).first?.severity
        let spent = StatusRender.rows(for: snapshot(0.99), mode: .used).first?.severity
        #expect(calm != spent, "every reading is drawn the same colour")
        #expect(spent == .critical)
    }

    /// A balance has no headroom to judge, so it takes the severity the
    /// provider reported and no bar in either mode.
    @Test("A balance draws no bar whichever way the meters are set")
    func balanceHasNoBarInEitherMode() {
        let s = Snapshot(providerID: "test",
                         gauges: [Gauge(id: "b", badge: "BAL", title: "Credits", used: 0,
                                        resetsAt: nil, reportedSeverity: .normal,
                                        amount: Gauge.Amount(value: 12.5, currency: "USD"))],
                         extras: [], accountLabel: nil, fetchedAt: Date())
        for mode in MeterMode.allCases {
            let row = StatusRender.rows(for: s, mode: mode).first
            #expect(row?.fill == nil, Comment(rawValue: "\(mode) drew a bar for a balance"))
            #expect(row?.percentText == "$12.50",
                    Comment(rawValue: "\(mode) showed a percentage for a balance"))
        }
    }
}
