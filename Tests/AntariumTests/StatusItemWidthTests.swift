import AppKit
import Foundation
import Testing
@testable import Antarium

/// How wide one agent's menu bar item can get.
///
/// The menu bar is shared with every other application's status item and has
/// one screen's width for all of them, so an item that grows without bound
/// does not merely look wrong — it pushes other people's items off the bar.
///
/// `Gauge`'s initialiser clamps its id, its badge, its title and its
/// fraction, with a comment arguing that the range each field documents
/// should be true by construction rather than by every provider remembering.
/// The amount was taken as given: its currency is vendor text, and its value
/// was checked only for being finite.
@Suite("A menu bar item stays a menu bar item", .serialized)
@MainActor
struct StatusItemWidthTests {

    private func width(value: Double, currency: String) -> CGFloat {
        let gauge = Gauge(id: "b", badge: "BAL", title: "Balance", used: 0,
                          amount: .init(value: value, currency: currency))
        let row = StatusRender.Row(fill: nil, percentText: gauge.amountText ?? "",
                                   resetText: "", severity: .normal)
        return Renderer.width(for: StatusRender(agentID: "deepseek", rows: [row],
                                                message: nil, stale: false))
    }

    /// A rough ceiling. One item this wide is already unreasonable; the
    /// figures it is guarding against were 540 and 1,993.
    private let ceiling: CGFloat = 200

    @Test("An ordinary balance is an ordinary width")
    func ordinaryBalance() {
        let w = width(value: 95.5, currency: "USD")
        #expect(w < 130, Comment(rawValue: "an ordinary balance rendered \(w)pt wide"))
    }

    @Test("A currency the service made up does not widen the bar",
          arguments: [8, 16, 64, 256])
    func longCurrencies(length: Int) {
        let w = width(value: 95.5, currency: String(repeating: "X", count: length))
        #expect(w < ceiling,
                Comment(rawValue: "a \(length)-character currency rendered \(w)pt wide"))
    }

    @Test("A balance too large to print in full does not widen the bar",
          arguments: [1e12, 1e30, 1e300, Double.greatestFiniteMagnitude])
    func hugeBalances(value: Double) {
        let w = width(value: value, currency: "USD")
        #expect(w < ceiling,
                Comment(rawValue: "a balance of \(value) rendered \(w)pt wide"))
    }

    /// And the figure is still the figure. Bounding the *width* must not
    /// become rounding the *number* — a shortened balance is a wrong balance,
    /// which is worse than a wide one.
    @Test("Every balance anybody really has is printed exactly as before")
    func ordinaryBalancesAreUnchanged() {
        let cases: [(Double, String, String)] = [
            (0, "USD", "$0.00"), (9.99, "USD", "$9.99"), (95.5, "USD", "$95.50"),
            (1_204, "USD", "$1204"), (8.25, "CNY", "8.25 CNY"),
            (999_999_999, "USD", "$999999999"),
        ]
        for (value, currency, expected) in cases {
            let gauge = Gauge(id: "b", badge: "B", title: "B", used: 0,
                              amount: .init(value: value, currency: currency))
            #expect(gauge.amountText == expected,
                    Comment(rawValue: "\(value) \(currency) printed as "
                            + "\(gauge.amountText ?? "nothing")"))
        }
    }

    /// A figure past the limit is still reported, not discarded. Refusing it
    /// would leave `amount` nil, which makes `hasMeter` true and draws a bar
    /// where there is no denominator — a number invented out of a broken one.
    @Test("A balance past the limit is still reported, in short form")
    func hugeBalancesAreStillReported() throws {
        let gauge = Gauge(id: "b", badge: "B", title: "B", used: 0,
                          amount: .init(value: 1e300, currency: "USD"))
        let text = try #require(gauge.amountText)
        #expect(text.count <= 16, Comment(rawValue: "\(text.count) characters: \(text)"))
        #expect(text.contains("e+"), Comment(rawValue: "not scientific notation: \(text)"))
        #expect(gauge.hasMeter == false, "the balance was dropped and a meter drawn instead")
    }

    /// A value that is not a number at all cannot reach the formatter.
    @Test("An unrepresentable value does not print as a word")
    func nonFiniteValues() {
        for value in [Double.nan, .infinity, -.infinity] {
            let gauge = Gauge(id: "b", badge: "B", title: "B", used: 0,
                              amount: .init(value: value, currency: "USD"))
            let text = gauge.amountText ?? ""
            #expect(!text.lowercased().contains("nan") && !text.lowercased().contains("inf"),
                    Comment(rawValue: "\(value) printed as \(text)"))
        }
    }
}
