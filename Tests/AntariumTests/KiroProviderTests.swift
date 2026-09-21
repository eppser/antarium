import Foundation
import Testing
@testable import Antarium

/// Kiro reports what has been used; Amp reports what is left. Reading one as
/// the other gives a gauge that is exactly wrong and entirely plausible.
@Suite("Kiro usage parsing")
struct KiroProviderTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 UTC

    private let report = """
    Estimated Usage | resets on 03/01 | KIRO FREE

    🎁 Bonus credits: 125/500 credits used, expires in 29 days

    Credits (10 of 50 covered in plan)
    ████████████████ 20%
    """

    @Test("The figures are amounts used, not amounts left")
    func usedNotRemaining() throws {
        let found = try KiroProvider.makeSnapshot(report, now: now)
        let bonus = try #require(found.gauges.first { $0.title.contains("Bonus") })
        #expect(bonus.used == 0.25, "125 of 500 used is a quarter gone, not three quarters")
        let plan = try #require(found.gauges.first { $0.title == "Credits" })
        #expect(plan.used == 0.2)
    }

    @Test("The emoji prefix is not part of the label")
    func emojiIsNotALabel() throws {
        let found = try KiroProvider.makeSnapshot(report, now: now)
        let titles = found.gauges.map(\.title)
        #expect(titles.contains("Bonus credits"))
        let clean = titles.allSatisfy { $0.first?.isLetter == true }
        #expect(clean, "a label started with something that is not a letter: \(titles)")
    }

    @Test("Colour codes and the progress bar do not become figures")
    func ansiIsStripped() throws {
        let coloured = "\u{1B}[1;32mCredits (10 of 50 covered in plan)\u{1B}[0m"
        let found = try KiroProvider.makeSnapshot(coloured, now: now)
        #expect(found.gauges.count == 1)
        #expect(found.gauges.first?.used == 0.2, "a colour code was read as a number")
        // The figure parses either way; the label is where an unstripped
        // escape shows up, because `m` terminates a colour code and is also a
        // letter, so "\u{1B}[1;32mCredits" reads as "mCredits".
        #expect(found.gauges.first?.title == "Credits")
    }

    @Test("stripANSI leaves ordinary text alone")
    func stripIsNarrow() {
        #expect(KiroProvider.stripANSI("plain text 12/34") == "plain text 12/34")
        #expect(KiroProvider.stripANSI("a\u{1B}[31mb") == "ab")
    }

    // MARK: - The reset date, whose year is not stated

    @Test("A reset later this year is this year")
    func resetLaterThisYear() throws {
        let found = try #require(KiroProvider.resetDate(in: "resets on 03/01", now: now))
        #expect(found > now)
        #expect(found.timeIntervalSince(now) < 365 * 86_400)
    }

    /// A date already past this year means the next one, or the gauge says a
    /// reset happened ten months ago.
    @Test("A reset already past this year rolls to next year")
    func resetRollsOver() throws {
        // now is mid-January; 01/01 has gone.
        let found = try #require(KiroProvider.resetDate(in: "resets on 01/01", now: now))
        #expect(found > now)
        #expect(found.timeIntervalSince(now) > 300 * 86_400)
    }

    /// Resolved in UTC, not through the local calendar: the same report has to
    /// give the same instant wherever it is read.
    @Test("The reset instant does not depend on where the machine is")
    func resetIsTimeZoneIndependent() throws {
        let found = try #require(KiroProvider.resetDate(in: "resets on 03/01", now: now))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.month, .day, .hour], from: found)
        #expect(parts.month == 3); #expect(parts.day == 1); #expect(parts.hour == 0)
    }

    @Test("An impossible or absent reset date is left out", arguments: [
        "resets on 13/01", "resets on 03/45", "resets on 3/1",
        "resets on ab/cd", "no reset here",
    ])
    func badResetDates(_ line: String) {
        #expect(KiroProvider.resetDate(in: line, now: now) == nil)
    }

    @Test("The reset date reaches the gauges")
    func resetReachesGauges() throws {
        let found = try KiroProvider.makeSnapshot(report, now: now)
        let dated = found.gauges.allSatisfy { $0.resetsAt != nil }
        #expect(dated)
    }

    // MARK: - Refusals

    @Test("A report with no readable figure is an error", arguments: [
        "", "Estimated Usage | KIRO FREE",
        "Credits (10 of 0 covered in plan)",
        // The other branch: a cap of zero has no denominator on either line
        // shape, and only covering one of them leaves the other untested.
        "Bonus credits: 10/0 credits used",
        "Bonus credits: of credits used",
    ])
    func unreadable(_ text: String) {
        #expect(throws: ProviderError.self) { _ = try KiroProvider.makeSnapshot(text, now: now) }
    }

    /// A number on a line that reports no usage is not a quota.
    @Test("Unrelated figures are not charted")
    func unrelatedFigures() {
        #expect(throws: ProviderError.self) {
            _ = try KiroProvider.makeSnapshot("Upgrade: 10/50 seats available", now: now)
        }
    }

    @Test("A flood of lines is bounded")
    func bounded() throws {
        let noise = (0..<5_000).map { "Line \($0): 1/2 credits used" }.joined(separator: "\n")
        let found = try KiroProvider.makeSnapshot(noise, now: now)
        #expect(found.gauges.count <= KiroProvider.maxLines)
    }
}
