import Foundation
import Testing
@testable import Antarium

/// A figure from before a reset is not old — it is wrong.
///
/// Staleness was already surfaced, and it answers a different question. "This
/// figure is old" tells the user to distrust it a little. But a window states when
/// it resets, and when that moment passes without a fresh reading, the service has
/// already replaced the figure — and this app has the evidence to know.
///
/// Claude's session window is five hours, so a credential that expires or a network
/// that drops for longer leaves a **spent bar on a window that has since refilled**.
/// That discourages the user from working, which is the exact inverse of the
/// inversion that started this audit and the same size of mistake.
@Suite("A window that reset since the reading no longer shows its figure", .serialized)
@MainActor
struct ResetSinceReadingTests {

    private let read = Date(timeIntervalSince1970: 1_790_000_000)

    private func gauge(used: Double = 0.9, resetsAt: Date?) -> Gauge {
        Gauge(id: "session", badge: "5H", title: "Session (5 hours)", used: used,
              resetsAt: resetsAt)
    }

    private func snapshot(_ gauge: Gauge, fetchedAt: Date) -> Snapshot {
        Snapshot(providerID: "claude-code", gauges: [gauge], extras: [],
                 accountLabel: "max plan", fetchedAt: fetchedAt)
    }

    // MARK: - The decision

    /// The case this exists for: read six hours ago, a five-hour window, so the
    /// window reset an hour ago and the reading predates it.
    @Test("A window whose reset passed after the reading is superseded")
    func supersededAfterReading() {
        let resets = read.addingTimeInterval(5 * 3600)
        #expect(gauge(resetsAt: resets).resetSince(reading: read,
                                                  now: read.addingTimeInterval(6 * 3600)))
    }

    /// A reading taken since the reset is current, however old it looks.
    @Test("A reading taken after the reset is not superseded")
    func readAfterTheReset() {
        let resets = read.addingTimeInterval(-3600)
        #expect(!gauge(resetsAt: resets).resetSince(reading: read, now: read.addingTimeInterval(60)))
    }

    /// A fresh reply whose reset is already past is left alone. That is the
    /// service's own inconsistency or a clock skew, and it just gave us the figure
    /// — second-guessing it would be inventing doubt.
    @Test("A fresh reply with a past reset keeps its figure")
    func freshReplyWithPastReset() {
        let resets = read.addingTimeInterval(-60)
        #expect(!gauge(resetsAt: resets).resetSince(reading: read, now: read))
    }

    /// Before the reset, nothing has been superseded.
    @Test("A window that has not reset yet is not superseded")
    func notYetReset() {
        let resets = read.addingTimeInterval(5 * 3600)
        #expect(!gauge(resetsAt: resets).resetSince(reading: read,
                                                   now: read.addingTimeInterval(3600)))
    }

    /// A window stating no reset can never be known to have reset. Absent is not
    /// evidence, which is the rule the whole project runs on.
    @Test("A window with no stated reset is never superseded")
    func noStatedReset() {
        #expect(!gauge(resetsAt: nil).resetSince(reading: read,
                                                 now: read.addingTimeInterval(86_400)))
    }

    /// Exactly at the reset: the window has reset, so the reading before it is
    /// superseded. A request sent now would arrive after it.
    @Test("Exactly at the reset, the earlier reading is superseded")
    func exactlyAtTheReset() {
        let resets = read.addingTimeInterval(3600)
        #expect(gauge(resetsAt: resets).resetSince(reading: read, now: resets))
    }

    // MARK: - What the menu bar draws

    @Test("The bar shows no fill and no figure for a superseded window")
    func barShowsNothing() throws {
        let resets = read.addingTimeInterval(5 * 3600)
        let rows = StatusRender.rows(for: snapshot(gauge(resetsAt: resets), fetchedAt: read),
                                    mode: .used, now: read.addingTimeInterval(6 * 3600))
        let row = try #require(rows.first)
        #expect(row.fill == nil, "a bar was drawn from a figure the service had replaced")
        #expect(row.percentText == "—",
                Comment(rawValue: "the figure read \"\(row.percentText)\""))
        // The row stays, and so does the reset — the window exists and when it
        // resets is still worth saying.
        #expect(!row.resetText.isEmpty)
    }

    /// And a current reading is untouched, in both meter modes, or the rule would
    /// be blanking every gauge.
    @Test("A current reading still draws its figure", arguments: MeterMode.allCases)
    func currentReadingIsUntouched(mode: MeterMode) throws {
        let resets = read.addingTimeInterval(5 * 3600)
        let rows = StatusRender.rows(for: snapshot(gauge(resetsAt: resets), fetchedAt: read),
                                    mode: mode, now: read.addingTimeInterval(3600))
        let row = try #require(rows.first)
        #expect(row.fill != nil, Comment(rawValue: "mode \(mode): the fill went missing"))
        #expect(row.percentText != "—")
    }

    /// A balance has no meter and no reset, so nothing about it changes.
    @Test("A balance is unaffected")
    func balanceIsUnaffected() throws {
        let balance = Gauge(id: "balance", badge: "BAL", title: "Balance", used: 0,
                            amount: Gauge.Amount(value: 12.5, currency: "USD"))
        let rows = StatusRender.rows(for: snapshot(balance, fetchedAt: read), mode: .used,
                                    now: read.addingTimeInterval(86_400))
        #expect(try #require(rows.first).percentText != "—")
    }

    // MARK: - What the dashboard says

    @Test("The tooltip says the window has reset rather than quoting the figure")
    func tooltipSaysReset() {
        let resets = read.addingTimeInterval(5 * 3600)
        let text = AccountQuotaBar.help(gauge: gauge(resetsAt: resets), plan: "max plan",
                                  fetchedAt: read, now: read.addingTimeInterval(6 * 3600))
        #expect(text.contains("reset since this was read"),
                Comment(rawValue: "the tooltip said: \(text)"))
        #expect(!text.contains("90%"), "the superseded figure was quoted anyway")
    }

    @Test("A current reading's tooltip still quotes the figure")
    func tooltipQuotesCurrent() {
        let resets = read.addingTimeInterval(5 * 3600)
        let text = AccountQuotaBar.help(gauge: gauge(resetsAt: resets), plan: "max plan",
                                  fetchedAt: read, now: read.addingTimeInterval(60))
        #expect(text.contains("90%"), Comment(rawValue: "the tooltip said: \(text)"))
        #expect(!text.contains("reset since"))
    }

    /// A reading with no known age cannot be shown to be superseded, so the figure
    /// stands — the same rule as a window with no stated reset.
    @Test("A reading of unknown age keeps its figure")
    func unknownAgeKeepsTheFigure() {
        let resets = read.addingTimeInterval(-86_400)
        let text = AccountQuotaBar.help(gauge: gauge(resetsAt: resets), plan: "max plan",
                                  fetchedAt: nil, now: read)
        #expect(!text.contains("reset since"))
    }
}
