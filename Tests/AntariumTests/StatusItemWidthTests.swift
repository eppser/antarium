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

    /// Every input the item draws, pushed as far as its reader allows, at
    /// once.
    ///
    /// The four separate bounds this suite checks were each found and fixed
    /// on its own. This is the invariant they add up to, stated once so that
    /// a field added later has something to fail against rather than waiting
    /// to be noticed in a menu bar.
    ///
    /// The renderer takes an agent id, up to two rows of percentage and
    /// countdown, and a message. The id becomes a glyph of fixed size. The
    /// message is one of seven words the app chooses itself. The countdown is
    /// bounded by the reader that produces the date — `FieldPath.epoch`
    /// refuses anything past the year 9999 — and the percentage by `Gauge`.
    @Test("Nothing a service can send makes this item wider than a menu bar item")
    func everyExtremeAtOnce() {
        // The furthest reset a date reader will accept, so the countdown is
        // the longest it can be.
        let latest = Date(timeIntervalSince1970: 253_402_300_799)
        func absurd(_ value: Double, _ currency: String) -> Gauge {
            Gauge(id: String(repeating: "i", count: 5_000),
                  badge: String(repeating: "B", count: 5_000),
                  title: String(repeating: "T", count: 5_000),
                  used: 1, resetsAt: latest, reportedSeverity: .critical,
                  amount: .init(value: value, currency: currency))
        }
        // Two *different* rows, and the wider one second. The item takes the
        // widest of its rows, so two identical ones cannot tell a renderer
        // that measures all of them from one that measures only the first.
        let rows = StatusRender.rows(for: Snapshot(
            providerID: "deepseek",
            gauges: [absurd(1, "$"), absurd(.greatestFiniteMagnitude,
                                            String(repeating: "C", count: 5_000))],
            extras: [], accountLabel: nil, fetchedAt: Date()))
        #expect(rows.count == 2, "the renderer draws at most two rows and this exercises both")
        #expect(rows[0].percentText != rows[1].percentText,
                "the two rows measure the same, so this cannot see which were measured")
        let w = Renderer.width(for: StatusRender(agentID: "deepseek", rows: rows,
                                                 message: nil, stale: true))
        #expect(w < ceiling,
                Comment(rawValue: "an item of every extreme at once rendered \(w)pt wide"))
        // A lower bound as well. "Narrower than a menu bar item" is satisfied
        // by an item of no width at all, and a renderer returning zero passed
        // every assertion here until this line was added.
        #expect(w > Renderer.glyphSize,
                Comment(rawValue: "the item rendered \(w)pt wide, which is not enough to "
                        + "draw the glyph it starts with"))
        // And the wider row is what set it.
        let narrowOnly = Renderer.width(for: StatusRender(agentID: "deepseek",
                                                          rows: [rows[0]],
                                                          message: nil, stale: true))
        #expect(w > narrowOnly,
                Comment(rawValue: "the second row did not widen the item: \(w) against "
                        + "\(narrowOnly)"))

        // And the message path, which is the other shape the item can take.
        for message in ["···", "set up", "sign in", "keychain", "offline", "error", "n/a"] {
            let m = Renderer.width(for: StatusRender(agentID: "deepseek", rows: [],
                                                     message: message, stale: false))
            #expect(m < ceiling,
                    Comment(rawValue: "the \"\(message)\" item rendered \(m)pt wide"))
            #expect(m > Renderer.glyphSize,
                    Comment(rawValue: "the \"\(message)\" item rendered \(m)pt wide"))
        }
    }

    /// And the countdown itself, which is bounded by the date reader rather
    /// than by anything in the renderer — so it is worth proving that bound
    /// is what keeps this short.
    @Test("The longest reset a reader will accept is still a short countdown")
    func countdownIsShort() {
        let latest = Date(timeIntervalSince1970: 253_402_300_799)
        let text = Format.shortCountdown(to: latest, now: Date(timeIntervalSince1970: 0))
        #expect(text.count <= 10, Comment(rawValue: "the countdown reads \(text)"))
        #expect(text.hasSuffix("d"))
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

/// The per-provider menu, which is the other surface a window's name reaches.
///
/// `NSMenu` does not truncate: a menu is as wide as its widest item. A title
/// at `Gauge`'s backstop of 4,096 characters produces a menu 33,470 points
/// wide — ten screens — and five hundred characters already overflows one.
///
/// Cut at the menu rather than in the model. A descriptor's label is trusted
/// local configuration and deliberately passes through unclamped, and the
/// same string appears in tooltips and diagnostic output where its length
/// costs nothing. This is the one place it is laid out.
@Suite("A provider's menu is as wide as a menu", .serialized)
@MainActor
struct MenuTitleWidthTests {

    private func menuWidth(_ title: String) -> CGFloat {
        let menu = NSMenu()
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        menu.addItem(item)
        return menu.size.width
    }

    /// The narrowest display this app supports, which is what a menu has to
    /// fit inside.
    private let smallestScreen: CGFloat = 1_280

    @Test("A title at the model's backstop still draws a usable menu")
    func backstopTitleFitsAScreen() {
        let atBackstop = String(repeating: "T", count: Gauge.maxTitle)
        let drawn = AgentItem.menuTitle(atBackstop)
        #expect(menuWidth(drawn) < smallestScreen,
                Comment(rawValue: "a \(atBackstop.count)-character title drew a "
                        + "\(menuWidth(drawn))pt menu"))
        // And the cut is visible rather than silent.
        #expect(drawn.hasSuffix("…"), "the title was cut with nothing to say so")
    }

    /// Without the cut the menu is unusable, which is what makes the cut
    /// worth having — stated so the bound is not mistaken for caution.
    @Test("The same title uncut does not fit any screen")
    func uncutTitleDoesNotFit() {
        let atBackstop = String(repeating: "T", count: Gauge.maxTitle)
        #expect(menuWidth(atBackstop) > 10_000,
                Comment(rawValue: "an uncut title drew a \(menuWidth(atBackstop))pt menu, "
                        + "so this suite is not measuring what it claims"))
    }

    /// Every name anybody writes passes through untouched. The longest the
    /// shipped harnesses declare is "Session (5 hours)".
    @Test("An authored window name is not cut",
          arguments: ["Session (5 hours)", "Weekly", "Monthly", "Code review", "Gateway credits",
                      "A window name long enough that nobody would write a longer one"])
    func authoredNamesSurvive(title: String) {
        #expect(AgentItem.menuTitle(title) == title,
                Comment(rawValue: "\"\(title)\" was cut at \(AgentItem.maxMenuTitle)"))
    }

    /// And the cut reaches the menu. The tests above call `menuTitle`
    /// directly, so they hold whether or not the item that draws a window's
    /// name passes through it — which is the same gap that let a plan label
    /// ship with its ceiling declared and unapplied.
    @Test("The item that draws a window's name is the one that cuts it")
    func theMenuItemUsesIt() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/AgentItem.swift"), encoding: .utf8)
        // The gauge row's own item, which is the one whose title is a
        // window's name.
        #expect(source.contains("string: Self.menuTitle(g.title)"),
                "a window's name reaches its menu item without being cut")
        // And nothing else hands a gauge title to a menu item raw.
        #expect(!source.contains("string: g.title"),
                "a gauge title is drawn somewhere without going through the cut")
    }

    /// And the cut lands between characters. A title cut through a
    /// multi-byte scalar puts a replacement glyph in a menu.
    @Test("An emoji title is cut between characters")
    func cutIsGraphemeSafe() {
        let title = String(repeating: "👩‍💻", count: 400)
        let drawn = AgentItem.menuTitle(title)
        #expect(drawn.count <= AgentItem.maxMenuTitle)
        #expect(!drawn.unicodeScalars.contains("\u{FFFD}"), "a character was cut in half")
    }
}
