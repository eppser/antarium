import Foundation
import Testing
@testable import Antarium

/// The two figures the menu bar can draw for one gauge.
///
/// A meter shows either what has been used or what is left, and the user
/// chooses which. Both come from the same fraction, so the pair has to agree
/// — and neither may round a sliver away into an absolute. "0% remaining"
/// when a fraction of a percent is left says you are out when you are not;
/// "100%" when a little has been spent says the opposite. `percentText` has
/// `<1%` and `>99%` for exactly that, and nothing held it there.
@Suite("Used and remaining agree, and neither rounds to an absolute")
struct PercentTextTests {

    private func gauge(_ used: Double) -> Gauge {
        Gauge(id: "g", badge: "B", title: "T", used: used)
    }

    /// Only a gauge that is genuinely empty or genuinely full reads as one.
    @Test("A sliver is never shown as none or all",
          arguments: [0.0001, 0.001, 0.005, 0.009, 0.991, 0.995, 0.999, 0.9999])
    func sliversAreNotAbsolutes(used: Double) {
        let g = gauge(used)
        for text in [g.usedPercentText, g.remainingPercentText] {
            #expect(text != "0%",
                    Comment(rawValue: "\(used) used reads as 0% — \(g.usedPercentText) / "
                            + "\(g.remainingPercentText)"))
            #expect(text != "100%",
                    Comment(rawValue: "\(used) used reads as 100% — \(g.usedPercentText) / "
                            + "\(g.remainingPercentText)"))
        }
    }

    /// And the absolutes are still reachable, or the rule above would be
    /// satisfied by never printing them at all.
    @Test("Empty and full read as empty and full")
    func absolutesAreReachable() {
        #expect(gauge(0).usedPercentText == "0%")
        #expect(gauge(0).remainingPercentText == "100%")
        #expect(gauge(1).usedPercentText == "100%")
        #expect(gauge(1).remainingPercentText == "0%")
    }

    /// The pair describes one gauge, so the two figures have to be
    /// complements — a bar that says "30% used" and "50% left" is two
    /// readings of the same number.
    @Test("The two figures are complements",
          arguments: [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0])
    func figuresAreComplements(used: Double) throws {
        let g = gauge(used)
        let a = try #require(Int(g.usedPercentText.dropLast()))
        let b = try #require(Int(g.remainingPercentText.dropLast()))
        #expect(a + b == 100,
                Comment(rawValue: "\(g.usedPercentText) used and \(g.remainingPercentText) "
                        + "left come to \(a + b)%"))
    }

    /// The figures a gauge cannot produce, asked of the function directly.
    ///
    /// `percentText` is `static` and takes a bare `Double`, and the settings
    /// preview calls it without a gauge in hand. Its last line converts to
    /// `Int`, which traps on a NaN, an infinity, or a magnitude past
    /// `Int.max` — so an unguarded argument is not a wrong string, it is the
    /// menu bar taking the app down. Going through `gauge()` here would prove
    /// nothing: the initialiser clamps, so the function would never see one.
    @Test("No fraction makes the percentage trap",
          arguments: [Double.nan, .infinity, -.infinity, 1e20, -1e20,
                      Double.greatestFiniteMagnitude, -5, 3.5, -0.5, 1.5])
    func anyFractionIsSurvivable(fraction: Double) {
        let text = Gauge.percentText(fraction)
        #expect(text.hasSuffix("%"))
        let figure = text.drop(while: { !$0.isNumber }).dropLast()
        let value = try? #require(Int(figure))
        #expect(value.map { (0...100).contains($0) } ?? false,
                Comment(rawValue: "\(fraction) produced \(text)"))
    }

    /// And a gauge clamps too, so neither layer is carrying the other.
    @Test("A gauge built from a fraction outside its range still reads sanely",
          arguments: [-1.0, -0.5, 1.5, 2.0, .infinity, -.infinity, .nan])
    func outOfRangeFractions(used: Double) {
        let g = gauge(used)
        for text in [g.usedPercentText, g.remainingPercentText] {
            #expect(text.hasSuffix("%"))
            #expect(!text.contains("-"),
                    Comment(rawValue: "\(used) produced \(text)"))
            #expect(!text.lowercased().contains("nan") && !text.lowercased().contains("inf"),
                    Comment(rawValue: "\(used) produced \(text)"))
        }
    }

    /// The clamp is shared with the initialiser, so it is worth saying what
    /// it does to a figure that is merely wrong rather than unrepresentable:
    /// it becomes an edge of the range, not a negative percentage.
    @Test("An impossible fraction lands on an edge, not past it")
    func clampLandsOnEdges() {
        #expect(Gauge.fraction(-3) == 0)
        #expect(Gauge.fraction(3) == 1)
        #expect(Gauge.fraction(.nan) == 0)
        #expect(Gauge.fraction(0.25) == 0.25)
        #expect(Gauge.percentText(-3) == "0%")
        #expect(Gauge.percentText(3) == "100%")
    }

    /// Both modes draw one of these, so the menu bar never shows a figure
    /// this suite has not seen.
    @Test("Every meter mode draws one of the two figures", arguments: MeterMode.allCases)
    func everyModeIsCovered(mode: MeterMode) {
        let g = gauge(0.42)
        let rows = StatusRender.rows(for: Snapshot(providerID: "p", gauges: [g], extras: [],
                                                   accountLabel: nil, fetchedAt: Date()),
                                     mode: mode)
        let drawn = rows.first?.percentText
        #expect(drawn == g.usedPercentText || drawn == g.remainingPercentText,
                Comment(rawValue: "\(mode) drew \(drawn ?? "nothing")"))
    }
}

/// What an empty balance says about itself.
///
/// A balance normally declines to colour itself: five hundred dollars and two
/// cents look the same without knowing what an account spends, so only a
/// severity the provider reported can make one urgent. Nought is not that
/// judgement. Nothing has to be known to tell that nothing is left, and
/// Moonshot documents the consequence outright — an available balance at or
/// below nought means the inference API cannot be called.
@Suite("An empty balance says so")
struct EmptyBalanceSeverityTests {

    private func balance(_ value: Double, reported: Severity = .normal) -> Gauge {
        Gauge(id: "b", badge: "BAL", title: "Balance", used: 0,
              reportedSeverity: reported,
              amount: Gauge.Amount(value: value, currency: "USD"))
    }

    @Test("Nothing left is critical", arguments: [0.0, -0.01, -12.5])
    func emptyIsCritical(value: Double) {
        #expect(balance(value).severity == .critical,
                Comment(rawValue: "a balance of \(value) reported \(balance(value).severity)"))
    }

    /// And the rule it does not overturn: a balance with money in it is still
    /// not judged, however small, because small is the thing this cannot know.
    @Test("Money left is not judged", arguments: [0.01, 2.0, 500.0])
    func moneyIsNotJudged(value: Double) {
        #expect(balance(value).severity == .normal,
                Comment(rawValue: "a balance of \(value) coloured itself"))
    }

    /// A provider's own verdict still wins where it is worse.
    @Test("A reported severity is not lowered by having money")
    func reportedSeverityStands() {
        #expect(balance(500, reported: .critical).severity == .critical)
        #expect(balance(0, reported: .low).severity == .critical)
    }

    /// A meter is unaffected: it has a denominator and judges itself from it.
    @Test("A meter still colours from its own headroom")
    func metersAreUnchanged() {
        let nearlyOut = Gauge(id: "m", badge: "5H", title: "Session", used: 0.99)
        #expect(nearlyOut.severity == .critical)
        let fresh = Gauge(id: "m", badge: "5H", title: "Session", used: 0.1)
        #expect(fresh.severity == .normal)
    }
}
