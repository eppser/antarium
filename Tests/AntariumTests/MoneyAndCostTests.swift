import Foundation
import Testing
@testable import Antarium

/// How an amount of money is written.
///
/// Four bands, none of which had a test: whole pounds above a hundred, one
/// decimal above ten, cents above a penny, and below that a statement that
/// something was spent rather than a figure claiming nothing was.
@Suite("Writing an amount of money")
struct MoneyFormattingTests {

    @Test("Large amounts lose their cents, which are noise at that size")
    func largeAmounts() {
        #expect(Pricing.money(100) == "$100")
        #expect(Pricing.money(1_234.56) == "$1235")
    }

    @Test("Amounts over ten keep one decimal")
    func middlingAmounts() {
        #expect(Pricing.money(10) == "$10.0")
        #expect(Pricing.money(99.94) == "$99.9")
    }

    @Test("Ordinary amounts keep their cents")
    func ordinaryAmounts() {
        #expect(Pricing.money(0.01) == "$0.01")
        #expect(Pricing.money(1.5) == "$1.50")
        #expect(Pricing.money(9.99) == "$9.99")
    }

    /// The band that matters most. A session that has spent a third of a
    /// penny has spent something, and writing "$0" says it has not — which
    /// is the difference between a number that is rounded and a number that
    /// is wrong.
    @Test("A fraction of a penny says so rather than reading as nothing")
    func slivers() {
        #expect(Pricing.money(0.009) == "<$0.01")
        #expect(Pricing.money(0.0000001) == "<$0.01")
    }

    @Test("Nothing spent is nothing, not a sliver")
    func zero() {
        #expect(Pricing.money(0) == "$0")
    }

    /// The boundaries, because each band is chosen by a comparison and an
    /// off-by-one in any of them shows as a figure in the wrong shape.
    /// A figure that rounds into the band above is written in that band's
    /// shape. Choosing the band first and rounding second gave "$100.0" and
    /// "$10.00" — the narrower band's precision on a number that had just
    /// left it, which is how this test found the bug rather than confirming
    /// it.
    @Test("A figure that rounds up is written in the band it rounds into")
    func boundariesRoundOutward() {
        #expect(Pricing.money(99.999) == "$100")
        #expect(Pricing.money(9.999) == "$10.0")
        #expect(Pricing.money(9.95) == "$9.95",
                "a figure that does not reach the band was widened into it")
    }

    /// Except at the penny, where rounding up would claim a penny was spent
    /// when less was.
    @Test("A figure below a penny is never rounded up into one")
    func pennyBoundaryDoesNotRoundUp() {
        #expect(Pricing.money(0.0099) == "<$0.01")
        #expect(Pricing.money(0.01) == "$0.01")
        #expect(Pricing.money(0.0101) == "$0.01")
    }
}

/// What a cost of nothing means.
@Suite("Estimating a cost")
struct EstimatedCostTests {

    /// An empty usage table is a transcript that recorded no model usage at
    /// all, which is not the same as one that used a model and was charged
    /// nothing. The first has no answer; the second has an answer of zero.
    /// Collapsing them puts "$0" on a row whose figures were never read.
    private func statsWithUsage() throws -> TranscriptStats {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-\(UUID()).jsonl")
        let line = #"{"message":{"model":"synthetic-model","usage":"#
            + #"{"input_tokens":1000,"output_tokens":1000}}}"#
        try (Data(line.utf8) + Data([10])).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try #require(TranscriptStats.of(file))
    }

    private func rate(input: Double) -> Pricing.Rate {
        Pricing.Rate(input: input, output: 1, cacheWrite5m: 1,
                     cacheWrite1h: 1, cacheRead: 1, contextWindow: 200_000)
    }

    /// A price table is a JSON file somebody edits by hand. A negative rate
    /// in it would subtract from the total — a session that had spent money
    /// showing as having earned some — so an implausible rate is no answer
    /// rather than a wrong one.
    @Test("A negative rate yields no cost rather than a negative one")
    func negativeRateHasNoCost() throws {
        let stats = try statsWithUsage()
        #expect(stats.estimatedCost { _ in self.rate(input: 1) } != nil,
                "the fixture produced no usage, so the next assertion proves nothing")
        #expect(stats.estimatedCost { _ in self.rate(input: -5) } == nil,
                "a negative price was charted")
    }

    @Test("A rate that is not a number yields no cost", arguments: [
        Double.nan, .infinity,
    ])
    func nonFiniteRateHasNoCost(_ value: Double) throws {
        #expect(try statsWithUsage().estimatedCost { _ in self.rate(input: value) } == nil)
    }

    @Test("No recorded usage has no cost, rather than a cost of nothing")
    func noUsageHasNoCost() {
        // A freshly made one has read nothing, which is the state a
        // transcript is in before any usage record is folded into it.
        let stats = TranscriptStats()
        let rate = Pricing.Rate(input: 1, output: 1, cacheWrite5m: 1,
                                cacheWrite1h: 1, cacheRead: 1, contextWindow: 200_000)
        #expect(stats.estimatedCost { _ in rate } == nil,
                "a transcript with no usage was costed at nothing")
    }
}
