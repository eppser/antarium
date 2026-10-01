import Foundation
import Testing
@testable import Antarium

/// The per-model weeks of Claude's older response shape.
///
/// The reply comes two ways: a generic `limits` array, and flat top-level windows.
/// This provider preferred `limits` and fell back to `five_hour` and `seven_day` —
/// and stopped there. Cross-read 2026-09-27 against the tool this app is measured
/// against: it reads `seven_day_sonnet` and `seven_day_opus`, and its own comment
/// says model-scoped limits appear in the newer `limits` array as `weekly_scoped`
/// *instead of* those dedicated fields. They are the older shape.
///
/// So an account still served that shape showed a session and one week while the
/// per-model weeks it also reported went unread — including, on a plan where a
/// model cap binds first, the week that would actually stop the user.
@Suite("Claude's older shape reports per-model weeks, and they are read")
struct ClaudeFlatWeekTests {

    private let token = ClaudeToken(accessToken: "synthetic", expiresAt: nil,
                                    subscriptionType: "max", source: .file)

    private func snapshot(_ json: String) throws -> Snapshot {
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                     as? [String: Any])
        return try ClaudeCodeProvider.makeSnapshot(reply, token: token)
    }

    /// The flat shape with a model week that binds harder than the plain one.
    @Test("A per-model week is read, and the hardest week is the one the bar tracks")
    func modelWeekBinds() throws {
        let snapshot = try snapshot(#"""
        {"five_hour":{"utilization":20,"resets_at":"2026-09-27T18:00:00Z"},
         "seven_day":{"utilization":30,"resets_at":"2026-10-01T00:00:00Z"},
         "seven_day_opus":{"utilization":91,"resets_at":"2026-10-01T00:00:00Z"}}
        """#)
        #expect(snapshot.gauges.count == 2)
        let week = try #require(snapshot.gauges.last)
        #expect(abs(week.used - 0.91) < 0.0001,
                Comment(rawValue: "the bar tracks \(week.used * 100)%, not the binding 91%"))
        #expect(week.title == "Weekly · Opus", Comment(rawValue: "titled \"\(week.title)\""))
        // And the week it is not tracking is still listed.
        #expect(snapshot.extras.count == 1)
        #expect(abs(try #require(snapshot.extras.first).used - 0.30) < 0.0001)
    }

    /// Several model weeks, all listed, ordered by how close they are.
    @Test("Every per-model week is listed")
    func everyModelWeekIsListed() throws {
        let snapshot = try snapshot(#"""
        {"five_hour":{"utilization":10},
         "seven_day":{"utilization":20},
         "seven_day_sonnet":{"utilization":55},
         "seven_day_opus":{"utilization":70}}
        """#)
        let titles = [snapshot.gauges.last?.title] + snapshot.extras.map(\.title)
        #expect(titles.compactMap { $0 }.count == 3,
                Comment(rawValue: "weeks reported: \(titles)"))
        #expect(snapshot.gauges.last?.title == "Weekly · Opus", "the hardest week binds")
        #expect(snapshot.extras.map(\.used).sorted(by: >) == snapshot.extras.map(\.used),
                "the listed weeks are not ordered by how close they are")
    }

    /// A model this app has never heard of is still shown, named from its own key.
    @Test("An unfamiliar model's week is named from the field rather than dropped")
    func unfamiliarModel() throws {
        let snapshot = try snapshot(#"""
        {"five_hour":{"utilization":10},"seven_day_fable":{"utilization":80}}
        """#)
        #expect(snapshot.gauges.last?.title == "Weekly · Fable",
                Comment(rawValue: "titled \"\(snapshot.gauges.last?.title ?? "nothing")\""))
    }

    /// The title reads the model as the API spells it, capitalised no further than
    /// its first letter — how somebody's model name is written is not this app's
    /// decision.
    @Test("A model key becomes a readable title", arguments: [
        ("seven_day_sonnet", "Weekly · Sonnet"),
        ("seven_day_opus", "Weekly · Opus"),
        ("seven_day_claude_next", "Weekly · Claude next"),
        ("seven_day_", "Weekly"),
    ])
    func titles(key: String, expected: String) {
        #expect(ClaudeCodeProvider.flatWeekTitle(key) == expected)
    }

    /// The keys are found in the reply rather than from a list of model names, and
    /// the plain `seven_day` is not one of them.
    @Test("Only the per-model keys are collected, in a stable order")
    func keysAreCollected() {
        let json: [String: Any] = ["seven_day": [:], "seven_day_opus": [:],
                                   "seven_day_sonnet": [:], "five_hour": [:], "spend": [:]]
        #expect(ClaudeCodeProvider.flatModelWeekKeys(json)
                == ["seven_day_opus", "seven_day_sonnet"])
    }

    /// The newer shape still wins. A reply carrying both must not read the flat
    /// windows at all, or a stale flat figure could outrank a live one.
    @Test("The limits array is still preferred over the flat windows")
    func limitsStillWin() throws {
        let snapshot = try snapshot(#"""
        {"limits":[{"kind":"session","percent":11},{"kind":"weekly_all","percent":22}],
         "five_hour":{"utilization":99},"seven_day":{"utilization":99},
         "seven_day_opus":{"utilization":99}}
        """#)
        #expect(abs(try #require(snapshot.gauges.first).used - 0.11) < 0.0001,
                "a flat window outranked the limits array")
        #expect(abs(try #require(snapshot.gauges.last).used - 0.22) < 0.0001)
        #expect(snapshot.extras.isEmpty, "a flat week was listed beside the limits array")
    }

    /// And a reply with no week at all is still refused, rather than the new
    /// fallback quietly inventing one.
    @Test("A reply with no weekly window is still refused")
    func noWeekIsStillRefused() throws {
        #expect(throws: ProviderError.self) {
            _ = try snapshot(#"{"five_hour":{"utilization":10}}"#)
        }
    }
}

/// Cursor's billing-cycle end, in every form it has been seen in.
///
/// Cross-read 2026-09-27 against the tool this app is measured against, which reads
/// a *different* Cursor endpoint — `cursor.com/api/usage-summary` — where this field
/// is an ISO string. The endpoint this app reads reports milliseconds, verified
/// against a live Pro account, so the two do not disagree. But a string that is not
/// a number fell through both numeric branches and came back with nothing, so a
/// reply in that shape showed no reset at all.
@Suite("Cursor reads its billing-cycle end however it is stated")
struct CursorBillingCycleTests {

    private func resets(_ value: String) throws -> Date? {
        let json = #"{"planUsage":{"totalPercentUsed":40},"billingCycleEnd":\#(value)}"#
        let usage = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                     as? [String: Any])
        return try CursorProvider.makeSnapshot(usage, planName: "Pro").gauges.first?.resetsAt
    }

    /// The verified shape: epoch milliseconds, as a number.
    @Test("Milliseconds as a number")
    func millisecondsNumber() throws {
        let when = 1_790_000_000.0
        let resets = try #require(try resets(String(Int(when * 1000))))
        #expect(abs(resets.timeIntervalSince1970 - when) < 1)
    }

    /// And as a numeric string, which the first branch already took.
    @Test("Milliseconds as a numeric string")
    func millisecondsString() throws {
        let when = 1_790_000_000.0
        let resets = try #require(try resets("\"\(Int(when * 1000))\""))
        #expect(abs(resets.timeIntervalSince1970 - when) < 1)
    }

    /// The form that used to read as nothing.
    @Test("An ISO date")
    func isoDate() throws {
        let resets = try #require(try resets("\"2026-10-01T00:00:00.000Z\""),
                                  "an ISO billing-cycle end read as no reset at all")
        #expect(resets.timeIntervalSince1970 == 1_790_812_800)
    }

    /// And something that is neither is still nothing, rather than a date invented
    /// from a string that happens to parse loosely.
    @Test("A value that is no date is no reset", arguments: [
        "\"next Tuesday\"", "\"\"", "null", "true", "0", "-1",
    ])
    func unreadable(value: String) throws {
        #expect(try resets(value) == nil,
                Comment(rawValue: "\(value) produced a reset"))
    }

    /// A reply omitting it has no reset, which is a reading rather than a failure.
    @Test("An absent field is no reset and no error")
    func absent() throws {
        let usage = try #require(try JSONSerialization.jsonObject(
            with: Data(#"{"planUsage":{"totalPercentUsed":40}}"#.utf8)) as? [String: Any])
        let snapshot = try CursorProvider.makeSnapshot(usage, planName: "Pro")
        #expect(snapshot.gauges.first?.resetsAt == nil)
        #expect(!snapshot.gauges.isEmpty, "the gauge went with the reset")
    }
}

/// A flag is not a figure, at every coercion the providers keep of their own.
///
/// `FieldPath.numeric` and `.integer` have refused booleans since they were
/// written. Four coercions local to the providers never did, and the sweep that
/// was supposed to find them grepped one code shape and reported an all-clear
/// that was wrong on four counts. `NSNumber` carries booleans and numbers alike,
/// so `as? Double`, `as? Int` and `as? Bool` each succeed on the wrong one.
///
/// What that cost: Cursor read `true` as one per cent used and as a billing cycle
/// ending a second after 1970; Claude read it as one per cent on both of its
/// response shapes; a stored credential read it as an expiry in 1970, which is a
/// token that reads as expired for ever.
@Suite("A flag is not a figure in any provider's own coercion")
struct BooleanIsNotAFigureTests {

    private let token = ClaudeToken(accessToken: "synthetic", expiresAt: nil,
                                    subscriptionType: nil, source: .file)

    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// The shared guard itself, over what a parsed reply carries.
    @Test("The guard tells a flag from a number")
    func guardIsRight() throws {
        let parsed = try json(#"{"flag":true,"off":false,"one":1,"zero":0,"text":"true"}"#)
        #expect(FieldPath.isBoolean(parsed["flag"]))
        #expect(FieldPath.isBoolean(parsed["off"]))
        #expect(!FieldPath.isBoolean(parsed["one"]), "the number one was called a flag")
        #expect(!FieldPath.isBoolean(parsed["zero"]))
        #expect(!FieldPath.isBoolean(parsed["text"]))
        #expect(!FieldPath.isBoolean(nil))
    }

    /// Cursor's percentage, which is the whole gauge.
    @Test("Cursor reads no percentage from a flag", arguments: ["true", "false"])
    func cursorPercent(literal: String) throws {
        let usage = try json(#"{"planUsage":{"totalPercentUsed":\#(literal)}}"#)
        let gauges = (try? CursorProvider.makeSnapshot(usage, planName: "Pro"))?.gauges ?? []
        #expect(gauges.isEmpty,
                Comment(rawValue: "totalPercentUsed: \(literal) drew \(gauges.count) gauge(s) "
                        + "at \(gauges.first?.used ?? -1)"))
    }

    /// And its billing cycle, which is where this was found.
    @Test("Cursor reads no billing cycle from a flag")
    func cursorCycle() throws {
        let usage = try json(#"{"planUsage":{"totalPercentUsed":40},"billingCycleEnd":true}"#)
        let snapshot = try CursorProvider.makeSnapshot(usage, planName: "Pro")
        #expect(snapshot.gauges.first?.resetsAt == nil,
                "a flag became a billing cycle ending a second after 1970")
    }

    /// Claude's newer shape.
    @Test("Claude reads no percentage from a flag in its limits array")
    func claudeLimitsPercent() throws {
        let reply = try json(#"""
        {"limits":[{"kind":"session","percent":true},{"kind":"weekly_all","percent":50}]}
        """#)
        // The session window is the one that cannot be read, so the whole reply is
        // refused rather than a one-per-cent session being drawn.
        #expect(throws: ProviderError.self) {
            _ = try ClaudeCodeProvider.makeSnapshot(reply, token: self.token)
        }
    }

    /// And its older one.
    @Test("Claude reads no utilization from a flag in its flat windows")
    func claudeFlatUtilization() throws {
        let reply = try json(#"""
        {"five_hour":{"utilization":true},"seven_day":{"utilization":50}}
        """#)
        #expect(throws: ProviderError.self) {
            _ = try ClaudeCodeProvider.makeSnapshot(reply, token: self.token)
        }
    }

    /// A real figure beside a flag is still read, so the guard skips the value
    /// rather than the reply.
    @Test("A flag in one window does not hide a figure in another")
    func flagDoesNotHideTheRest() throws {
        let reply = try json(#"""
        {"limits":[{"kind":"session","percent":25},{"kind":"weekly_all","percent":true},
                   {"kind":"weekly_scoped","percent":60}]}
        """#)
        let snapshot = try ClaudeCodeProvider.makeSnapshot(reply, token: token)
        #expect(abs(try #require(snapshot.gauges.first).used - 0.25) < 0.0001)
        #expect(abs(try #require(snapshot.gauges.last).used - 0.60) < 0.0001,
                "the unreadable week hid the readable one")
    }

    /// A stored credential's expiry. A flag read as 1 is an expiry in 1970, and a
    /// token that expired in 1970 reads as expired for ever.
    @Test("A credential expiry stated as a flag is no expiry")
    func credentialExpiry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bool-expiry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"synthetic","expiresAt":true}}"#.utf8)
            .write(to: file)
        let parsed = try #require(ClaudeCredentials.fromFile(file))
        #expect(parsed.expiresAt == nil, "a flag became an expiry")
        #expect(!parsed.isExpired, "a usable token read as expired for ever")
    }

    /// Ordinary figures still read, or the guard would be satisfied by refusing
    /// everything.
    @Test("Real numbers are unaffected")
    func realNumbersStillRead() throws {
        let usage = try json(#"{"planUsage":{"totalPercentUsed":40},"billingCycleEnd":1790000000000}"#)
        let snapshot = try CursorProvider.makeSnapshot(usage, planName: "Pro")
        #expect(abs(try #require(snapshot.gauges.first).used - 0.4) < 0.0001)
        #expect(snapshot.gauges.first?.resetsAt != nil)
    }
}
