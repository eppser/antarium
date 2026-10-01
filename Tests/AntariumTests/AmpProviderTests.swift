import Foundation
import Testing
@testable import Antarium

/// Amp reports in text. These are the shapes its own parsing fixtures use,
/// with every figure replaced — the point is the grammar, not the amounts.
@Suite("Amp usage parsing")
struct AmpProviderTests {

    private let capped = """
    Signed in as person@example.invalid (person)
    Amp Free: $15/$20 remaining (replenishes +$0.83/hour) [+100% bonus for 19 more days] - https://example.invalid/settings
    Individual credits: $0 remaining - https://example.invalid/settings
    """

    @Test("A capped line becomes a meter, and the cap is the denominator")
    func cappedLine() throws {
        let found = try AmpProvider.makeSnapshot(capped)
        let free = try #require(found.gauges.first { $0.title == "Amp Free" })
        #expect(free.used == 0.25, "$15 of $20 left is a quarter used")
    }

    /// The replenishment rate is a dollar figure later in the same line.
    /// Reading the last `$` instead of the first would chart $0.83/hour.
    @Test("A price quoted later in the line is not the figure")
    func laterPriceIsIgnored() throws {
        let found = try AmpProvider.makeSnapshot(
            "Amp Free: $15/$20 remaining (replenishes +$0.83/hour)")
        #expect(found.gauges.first?.used == 0.25)
    }

    @Test("An uncapped line becomes a balance, not a meter")
    func uncappedLine() throws {
        let found = try AmpProvider.makeSnapshot(
            "Individual credits: $50 remaining - https://example.invalid/settings")
        let gauge = try #require(found.gauges.first)
        #expect(gauge.amount?.value == 50)
        #expect(gauge.amount?.currency == "USD")
        #expect(gauge.used == 0, "a balance has no meter to fill")
    }

    @Test("Both kinds in one reply keep the meter as the headline")
    func bothKinds() throws {
        let found = try AmpProvider.makeSnapshot(capped)
        #expect(found.gauges.map(\.title) == ["Amp Free"])
        #expect(found.extras.map(\.title) == ["Individual credits"])
    }

    @Test("A spent quota reads as spent")
    func spent() throws {
        let found = try AmpProvider.makeSnapshot("Amp Free: $0/$20 remaining")
        #expect(found.gauges.first?.used == 1)
    }

    /// The email is on the first line of every real reply and nothing here
    /// needs it.
    @Test("The signed-in line is not read")
    func emailIsNotRead() throws {
        let found = try AmpProvider.makeSnapshot(capped)
        let mentions = (found.gauges + found.extras).contains {
            $0.title.contains("@") || $0.id.contains("@")
        }
        #expect(!mentions)
    }

    @Test("A reply with no readable figure is an error, not an empty gauge", arguments: [
        "",
        "Signed in as person@example.invalid (person)",
        "Amp Free: unavailable",
        "Amp Free: $ remaining",
        "Amp Free: $15/$ remaining",
        "Amp Free: $15/20 remaining",
    ])
    func unreadableReplies(_ text: String) {
        #expect(throws: ProviderError.self) { _ = try AmpProvider.makeSnapshot(text) }
    }

    /// Every figure Amp reports is on a line saying what is left. A dollar
    /// amount on any other line is something else — a rate, a price, a note —
    /// and charting it would be inventing a quota out of prose.
    @Test("A dollar figure on a line that reports no headroom is not a quota", arguments: [
        "Upgrade: $20/month - https://example.invalid/settings",
        "Overage is billed at $0.83 per hour",
        "Team plan: $99/$0 per seat",
        // This one is the case that matters: it parses perfectly as a capped
        // figure and would chart as 25% used. Only the absence of "remaining"
        // says it is a price list rather than a quota. The three above are
        // rejected by the number scanner whether the marker is required or
        // not, so on their own they prove nothing.
        "Team plan: $15/$20 per seat",
    ])
    func figuresOutsideAUsageLine(_ text: String) {
        #expect(throws: ProviderError.self) { _ = try AmpProvider.makeSnapshot(text) }
    }

    /// A cap of zero has no denominator, so there is no percentage to report.
    /// Charting it as 100% used would be inventing the figure.
    @Test("A zero cap is not charted")
    func zeroCap() {
        #expect(throws: ProviderError.self) {
            _ = try AmpProvider.makeSnapshot("Amp Free: $0/$0 remaining")
        }
    }

    @Test("A flood of lines is bounded and long labels are refused")
    func bounded() throws {
        let noise = (0..<5_000).map { "Line \($0): $1/$2 remaining" }.joined(separator: "\n")
        let found = try AmpProvider.makeSnapshot(noise)
        #expect(found.gauges.count <= AmpProvider.maxLines)
        // Long enough to exceed the label cap, short enough that the line
        // itself is not truncated — at 500 characters the truncation clipped
        // the word "remaining" and this passed because a different guard
        // rejected it, which is not what it claims to test.
        let long = String(repeating: "L", count: 100)
        #expect(long.count > 64 && long.count + 20 < AmpProvider.maxLineLength)
        #expect(throws: ProviderError.self) {
            _ = try AmpProvider.makeSnapshot("\(long): $1/$2 remaining")
        }
    }

    @Test("Figures that are not finite cannot become a balance")
    func nonFinite() {
        #expect(throws: ProviderError.self) {
            _ = try AmpProvider.makeSnapshot(
                "Amp Free: $\(String(repeating: "9", count: 400)) remaining")
        }
    }
}
