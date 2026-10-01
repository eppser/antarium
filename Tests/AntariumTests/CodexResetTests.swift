import Foundation
import Testing
@testable import Antarium

/// Codex's reset time and window length, in the shapes an independent
/// implementation has demonstrated Codex reports.
///
/// The verified fields for the HTTP endpoint this provider reads are
/// `used_percent` and `limit_window_seconds` — no reset among them — so a Codex
/// gauge showed a window length and no countdown where Claude's showed both.
/// The tool this app is measured against fixed its own Codex countdown on
/// 2026-09-25 by carrying `resetsAt` (epoch seconds) and `windowDurationMins`
/// out of Codex's *app-server RPC*: a different transport, camelCase where this
/// reply is snake_case.
///
/// Both are candidates now. A field absent from the reply changes nothing, so
/// adding one cannot produce a wrong figure — and a field present turns a missing
/// countdown into a real one. The unit conversion is the part that could go
/// wrong, so it has its own cases.
@Suite("Codex's reset and window length are read in every shape seen")
struct CodexResetTests {

    private func snapshot(_ json: String) throws -> Snapshot {
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                     as? [String: Any])
        return try CodexProvider.makeSnapshot(reply)
    }

    private func window(_ fields: String) -> String {
        #"{"rate_limit":{"primary_window":{"used_percent":40,\#(fields)}}}"#
    }

    /// The shape that was already read, unchanged.
    @Test("A window length in seconds is read as seconds")
    func secondsWindow() throws {
        let gauge = try #require(try snapshot(window(#""limit_window_seconds":18000"#)).gauges.first)
        #expect(gauge.windowSeconds == 18_000)
    }

    /// The new one, and the case that matters: minutes, converted.
    @Test("A window length in minutes is converted, not taken as seconds")
    func minutesWindow() throws {
        let gauge = try #require(try snapshot(window(#""windowDurationMins":300"#)).gauges.first)
        #expect(gauge.windowSeconds == 18_000,
                Comment(rawValue: "300 minutes read as \(gauge.windowSeconds ?? -1) seconds"))
    }

    /// And the title derived from it is the five-hour window's, not a twelve-day
    /// one — which is what taking minutes for seconds would have named it.
    @Test("A window in minutes is named for the length it really is")
    func minutesWindowIsNamed() throws {
        let minutes = try #require(try snapshot(window(#""windowDurationMins":300"#)).gauges.first)
        let seconds = try #require(try snapshot(window(#""limit_window_seconds":18000"#)).gauges.first)
        #expect(minutes.title == seconds.title,
                Comment(rawValue: "minutes named \"\(minutes.title)\", seconds "
                        + "\"\(seconds.title)\""))
    }

    /// Seconds win where both are present, since that is the field this endpoint
    /// is verified to carry.
    @Test("A length in seconds is preferred over one in minutes")
    func secondsPreferred() throws {
        let gauge = try #require(try snapshot(
            window(#""limit_window_seconds":18000,"windowDurationMins":9999"#)).gauges.first)
        #expect(gauge.windowSeconds == 18_000)
    }

    /// The reset, in each shape.
    @Test("A reset stated as camelCase epoch seconds is read")
    func camelCaseEpochReset() throws {
        let when = 1_790_000_000.0
        let gauge = try #require(try snapshot(window(#""resetsAt":\#(Int(when))"#)).gauges.first)
        let resets = try #require(gauge.resetsAt, "resetsAt was not read")
        #expect(abs(resets.timeIntervalSince1970 - when) < 1)
    }

    @Test("A reset stated as snake_case epoch seconds is still read")
    func snakeCaseEpochReset() throws {
        let when = 1_790_000_000.0
        let gauge = try #require(try snapshot(window(#""reset_at":\#(Int(when))"#)).gauges.first)
        #expect(abs(try #require(gauge.resetsAt).timeIntervalSince1970 - when) < 1)
    }

    @Test("A reset stated as camelCase text is read as a date")
    func camelCaseIsoReset() throws {
        let gauge = try #require(try snapshot(
            window(#""resetsAt":"2026-10-01T00:00:00Z""#)).gauges.first)
        #expect(try #require(gauge.resetsAt).timeIntervalSince1970 == 1_790_812_800)
    }

    @Test("A window stating no reset has none, rather than one invented")
    func noReset() throws {
        let gauge = try #require(try snapshot(window(#""limit_window_seconds":18000"#)).gauges.first)
        #expect(gauge.resetsAt == nil)
    }

    /// An unreadable reset is no reset. Every one of these reaches `Int(...)`
    /// further on, which is why the bounds exist.
    @Test("A reset that cannot be read is absent, not a trap", arguments: [
        #""resetsAt":1e30"#, #""resetsAt":-1"#, #""resetsAt":0"#,
        #""resetsAt":"tomorrow""#, #""resetsAt":true"#,
    ])
    func unreadableReset(field: String) throws {
        let gauge = try #require(try snapshot(window(field)).gauges.first)
        #expect(gauge.resetsAt == nil, Comment(rawValue: "\(field) produced a reset"))
    }

    /// And an absurd window length in minutes is refused the same way a length
    /// in seconds is — the conversion must not smuggle one past the bound.
    @Test("An absurd window length in minutes is refused", arguments: [
        #""windowDurationMins":1e30"#, #""windowDurationMins":-5"#,
        #""windowDurationMins":999999999"#,
    ])
    func absurdMinutes(field: String) throws {
        let gauge = try #require(try snapshot(window(field)).gauges.first)
        #expect(gauge.windowSeconds == nil, Comment(rawValue: "\(field) produced a window"))
    }
}

/// A boolean is not a figure, in any field of this reply.
///
/// Found by adding `true` to a parameterised list of unreadable resets. A boolean
/// is an `NSNumber` and bridges to `Int` as 0 or 1, so `"resetsAt": true` read as
/// a reset one second after 1970 — and the same helper reads every numeric field
/// here, so `"used_percent": true` read as one per cent used. `FieldPath` has
/// always refused booleans as figures; this provider's own helper never got the
/// guard.
@Suite("A boolean is not a figure in a Codex reply")
struct CodexBooleanFieldTests {

    private func snapshot(_ json: String) throws -> Snapshot? {
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                     as? [String: Any])
        return try? CodexProvider.makeSnapshot(reply)
    }

    /// The figure the whole gauge is: read as a boolean it became one per cent,
    /// which is a comfortable bar on an account that reported nothing readable.
    @Test("A percentage stated as a flag is no percentage", arguments: ["true", "false"])
    func percentAsFlag(literal: String) throws {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":\#(literal),"#
            + #""limit_window_seconds":18000}}}"#
        let gauges = try snapshot(json)?.gauges ?? []
        #expect(gauges.isEmpty,
                Comment(rawValue: "used_percent: \(literal) produced "
                        + "\(gauges.count) gauge(s) at \(gauges.first?.used ?? -1)"))
    }

    @Test("A window length stated as a flag is no length", arguments: ["true", "false"])
    func windowAsFlag(literal: String) throws {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":40,"#
            + #""limit_window_seconds":\#(literal)}}}"#
        let gauge = try #require(try snapshot(json)?.gauges.first)
        #expect(gauge.windowSeconds == nil,
                Comment(rawValue: "limit_window_seconds: \(literal) produced a window"))
    }

    /// And a flag in one candidate does not stop a real figure in the next being
    /// read — the guard skips the field rather than abandoning the list.
    @Test("A flag in one candidate field leaves the next one readable")
    func flagSkipsToTheNextCandidate() throws {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":40,"#
            + #""limit_window_seconds":true,"window_seconds":18000}}}"#
        let gauge = try #require(try snapshot(json)?.gauges.first)
        #expect(gauge.windowSeconds == 18_000,
                "a boolean in the first candidate hid a real figure in the second")
    }

    /// Real numbers still read, or the guard would be satisfied by refusing
    /// everything.
    @Test("Ordinary numbers are unaffected")
    func numbersStillRead() throws {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":40,"#
            + #""limit_window_seconds":18000}}}"#
        let gauge = try #require(try snapshot(json)?.gauges.first)
        #expect(abs(gauge.used - 0.4) < 0.0001)
        #expect(gauge.windowSeconds == 18_000)
    }
}
