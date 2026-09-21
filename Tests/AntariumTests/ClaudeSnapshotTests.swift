import Foundation
import Testing
@testable import Antarium

/// The mapping behind the Claude gauge — the one most users of this app read
/// most often — had no tests. It was found by a rule rather than by looking,
/// which is the point of having the rule.
@Suite("Claude usage mapping")
struct ClaudeSnapshotTests {

    private let token = ClaudeToken(accessToken: "synthetic", expiresAt: nil,
                                    subscriptionType: "max", source: .file)

    private func limit(_ group: String, _ kind: String, percent: Double,
                       model: String? = nil, resets: String? = nil) -> [String: Any] {
        var entry: [String: Any] = ["group": group, "kind": kind, "percent": percent]
        if let model { entry["scope"] = ["model": ["display_name": model]] }
        if let resets { entry["resets_at"] = resets }
        return entry
    }

    @Test("Session and the binding week are the two gauges")
    func twoGauges() throws {
        let found = try ClaudeCodeProvider.makeSnapshot(
            ["limits": [limit("session", "session", percent: 40),
                        limit("weekly", "weekly_all", percent: 60)]], token: token)
        #expect(found.gauges.map(\.id) == ["session", "weekly"])
        #expect(found.gauges[0].used == 0.4)
        #expect(found.gauges[1].used == 0.6)
    }

    /// The week you hit first is the highest of the weekly caps. Taking the
    /// first, or the lowest, gives a bar that reads comfortable while a
    /// different cap is about to stop you working.
    @Test("The binding week is the highest weekly cap, not the first")
    func bindingWeekIsTheWorst() throws {
        let found = try ClaudeCodeProvider.makeSnapshot(
            ["limits": [limit("session", "session", percent: 10),
                        limit("weekly", "weekly_all", percent: 20),
                        limit("weekly", "weekly_scoped", percent: 95, model: "Opus")]],
            token: token)
        let week = try #require(found.gauges.first { $0.id == "weekly" })
        #expect(week.used == 0.95)
        #expect(week.title == "Weekly · Opus")
        #expect(found.extras.map(\.title) == ["Weekly (all models)"],
                "the other caps belong in the dropdown, not discarded")
    }

    @Test("Remaining weeklies are listed worst first")
    func extrasAreOrdered() throws {
        let found = try ClaudeCodeProvider.makeSnapshot(
            ["limits": [limit("session", "session", percent: 1),
                        limit("weekly", "weekly_scoped", percent: 90, model: "Opus"),
                        limit("weekly", "weekly_scoped", percent: 30, model: "Sonnet"),
                        limit("weekly", "weekly_all", percent: 50)]],
            token: token)
        #expect(found.extras.map(\.used) == [0.5, 0.3])
    }

    @Test("A flat response without a limits array still maps")
    func flatShape() throws {
        let found = try ClaudeCodeProvider.makeSnapshot(
            ["five_hour": ["utilization": 25], "seven_day": ["utilization": 75]], token: token)
        #expect(found.gauges.map(\.used) == [0.25, 0.75])
        #expect(found.gauges.map(\.title) == ["Session (5 hours)", "Weekly"])
    }

    @Test("A response missing either window is an error, not a half-drawn bar", arguments: [
        ["limits": [["group": "weekly", "kind": "weekly_all", "percent": 10.0]]] as [String: Any],
        ["limits": [["group": "session", "kind": "session", "percent": 10.0]]],
        [:],
        ["limits": []],
    ])
    func missingWindows(_ json: [String: Any]) {
        #expect(throws: ProviderError.self) {
            _ = try ClaudeCodeProvider.makeSnapshot(json, token: token)
        }
    }

    @Test("An entry with no percentage is skipped rather than charted at zero")
    func unreadableEntriesAreSkipped() throws {
        let found = try ClaudeCodeProvider.makeSnapshot(
            ["limits": [limit("session", "session", percent: 10),
                        ["group": "weekly", "kind": "weekly_all"],
                        limit("weekly", "weekly_scoped", percent: 40, model: "Opus")]],
            token: token)
        #expect(found.gauges.last?.used == 0.4)
        #expect(found.extras.isEmpty, "an entry with no figure became a row")
    }

    @Test("The reset time is carried through when the service gives one")
    func resetIsCarried() throws {
        let found = try ClaudeCodeProvider.makeSnapshot(
            ["limits": [limit("session", "session", percent: 10, resets: "2026-10-01T00:00:00Z"),
                        limit("weekly", "weekly_all", percent: 20)]], token: token)
        #expect(found.gauges[0].resetsAt == Date(timeIntervalSince1970: 1_790_812_800))
        #expect(found.gauges[1].resetsAt == nil, "a window with no reset must not borrow one")
    }

    @Test("The plan is named from the token, not from the response")
    func planLabel() throws {
        let found = try ClaudeCodeProvider.makeSnapshot(
            ["limits": [limit("session", "session", percent: 1),
                        limit("weekly", "weekly_all", percent: 1)]], token: token)
        #expect(found.accountLabel == "max plan")
    }
}
