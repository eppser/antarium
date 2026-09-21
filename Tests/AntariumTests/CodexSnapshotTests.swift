import Foundation
import Testing
@testable import Antarium

/// Codex's mapping satisfied the coverage rule because a privacy test called
/// it in passing. Three mutations of it survived, which is what that kind of
/// coverage is worth.
@Suite("Codex usage mapping")
struct CodexSnapshotTests {

    private func window(_ percent: Double, seconds: Double? = nil) -> [String: Any] {
        var w: [String: Any] = ["used_percent": percent]
        if let seconds { w["limit_window_seconds"] = seconds }
        return w
    }

    @Test("The primary and secondary windows both become gauges")
    func bothWindows() throws {
        let found = try CodexProvider.makeSnapshot(
            ["rate_limit": ["primary_window": window(40, seconds: 18_000),
                            "secondary_window": window(10, seconds: 604_800)]])
        #expect(found.gauges.count == 2)
        #expect(found.gauges.map(\.used) == [0.4, 0.1])
    }

    /// The fast-moving window is the one worth watching, so it goes on top.
    /// Sorted the other way, a seven-day cap sits above a five-hour one and
    /// the row that changes while you work is the one underneath.
    @Test("The shortest window is the top row")
    func shortestFirst() throws {
        let found = try CodexProvider.makeSnapshot(
            ["rate_limit": ["primary_window": window(10, seconds: 604_800),
                            "secondary_window": window(40, seconds: 18_000)]])
        #expect(found.gauges.first?.used == 0.4, "the five-hour window belongs on top")
        #expect(found.gauges.map(\.windowSeconds) == [18_000, 604_800])
    }

    @Test("A window with no stated length sorts after one that has a length")
    func unknownLengthSortsLast() throws {
        let found = try CodexProvider.makeSnapshot(
            ["rate_limit": ["primary_window": window(10),
                            "secondary_window": window(40, seconds: 18_000)]])
        #expect(found.gauges.first?.used == 0.4)
    }

    /// The entries here are wrappers — `{limit_name, rate_limit: {...}}` — not
    /// windows. Handing the wrapper to the window parser finds no
    /// `used_percent` at its top level and drops every model-specific cap
    /// silently. That happened, and nothing was stopping it happening again.
    @Test("Model-specific caps are read out of their wrapper, not dropped")
    func additionalCapsAreUnwrapped() throws {
        let found = try CodexProvider.makeSnapshot([
            "rate_limit": ["primary_window": window(5, seconds: 604_800)],
            "additional_rate_limits": [
                ["limit_name": "Synthetic Spark",
                 "rate_limit": ["primary_window": window(80, seconds: 18_000)]]]])
        let extra = try #require(found.extras.first)
        #expect(extra.title == "Synthetic Spark")
        #expect(extra.used == 0.8, "the only five-hour window lives in here")
    }

    @Test("An additional cap with no name is still reported")
    func unnamedAdditionalCap() throws {
        let found = try CodexProvider.makeSnapshot([
            "rate_limit": ["primary_window": window(5, seconds: 604_800)],
            "additional_rate_limits": [
                ["metered_feature": "synthetic-feature",
                 "rate_limit": ["primary_window": window(50)]]]])
        #expect(found.extras.first?.title == "synthetic-feature")
    }

    @Test("Code review is reported alongside, not as the headline")
    func codeReviewIsAnExtra() throws {
        let found = try CodexProvider.makeSnapshot([
            "rate_limit": ["primary_window": window(5, seconds: 18_000),
                           "code_review_rate_limit": window(70, seconds: 18_000)]])
        #expect(found.gauges.map(\.used) == [0.05])
        #expect(found.extras.map(\.title) == ["Code review"])
    }

    /// A reply with nothing chartable in it is a failure. Returning an empty
    /// snapshot would show a provider with no rows and no error, which reads
    /// as "nothing used" rather than "nothing known".
    @Test("A reply with no usable window is an error, not an empty snapshot", arguments: [
        [:] as [String: Any],
        ["rate_limit": [:]],
        ["rate_limit": ["primary_window": ["something_else": 1]]],
        ["plan_type": "synthetic"],
    ])
    func emptyRepliesThrow(_ json: [String: Any]) {
        #expect(throws: ProviderError.self) { _ = try CodexProvider.makeSnapshot(json) }
    }

    @Test("The plan is named when the reply states one")
    func planLabel() throws {
        let found = try CodexProvider.makeSnapshot(
            ["plan_type": "synthetic",
             "rate_limit": ["primary_window": window(1, seconds: 18_000)]])
        #expect(found.accountLabel == "synthetic plan")
    }

    /// A flat reply with no `rate_limit` envelope is still read: the mapping
    /// falls back to the top level, and an envelope that is simply absent is
    /// a different shape rather than an empty one.
    @Test("A flat reply without the envelope still maps")
    func flatReply() throws {
        let found = try CodexProvider.makeSnapshot(
            ["primary_window": window(25, seconds: 18_000)])
        #expect(found.gauges.map(\.used) == [0.25])
    }
}
