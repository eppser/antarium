import Foundation
import Testing
@testable import Antarium

/// The fast path must agree with the formatter exactly, or it is not a fast
/// path, it is a second date parser with its own opinions.
@Suite("ISO-8601 fast path")
struct FastDateParsingTests {

    /// The formatter, reached deliberately — the same two the slow path uses.
    private func viaFormatter(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    @Test("Every accepted shape parses to the same instant the formatter gives")
    func fastPathAgreesWithTheFormatter() {
        let samples = [
            "2026-09-20T18:30:00Z",
            "2026-09-20T18:30:00.000Z",
            "2026-09-20T18:30:00.123Z",
            "2026-09-20T18:30:00.123456Z",
            "1970-01-01T00:00:00Z",
            "1969-12-31T23:59:59Z",
            "2000-02-29T12:00:00Z",       // leap day
            "2100-03-01T00:00:00Z",       // 2100 is not a leap year
            "2026-12-31T23:59:59.999Z",
            "2026-01-01T00:00:00.5Z",
        ]
        for sample in samples {
            let fast = UsageHTTP.fastUTC(sample)
            #expect(fast != nil, "fast path refused \(sample)")
            guard let fast, let slow = viaFormatter(sample) else { continue }
            // Sub-millisecond agreement; the formatter itself rounds.
            #expect(abs(fast.timeIntervalSince1970 - slow.timeIntervalSince1970) < 0.0005,
                    "\(sample): fast \(fast.timeIntervalSince1970) vs slow \(slow.timeIntervalSince1970)")
        }
    }

    @Test("Shapes the fast path declines still parse, through the formatter")
    func otherShapesFallThrough() {
        // Offsets and non-UTC forms are the formatter's job. The point is that
        // parseDate still returns them, so declining is not losing.
        for text in ["2026-09-20T18:30:00+02:00", "2026-09-20T18:30:00-0500"] {
            #expect(UsageHTTP.fastUTC(text) == nil, "fast path should decline \(text)")
            #expect(UsageHTTP.parseDate(text) == viaFormatter(text))
        }
    }

    @Test("An impossible or malformed date is refused, not silently shifted")
    func malformedDatesAreRefused() {
        // 31 February is 3 March in plain day arithmetic. The formatter
        // rejects it, so the fast path must too.
        for text in [
            "2026-02-31T00:00:00Z", "2026-13-01T00:00:00Z", "2026-00-10T00:00:00Z",
            "2026-09-32T00:00:00Z", "2026-09-20T24:00:00Z", "2026-09-20T18:60:00Z",
            "2025-02-29T00:00:00Z",                     // not a leap year
            "2026-09-20T18:30:00", "2026-09-20 18:30:00Z", "2026-09-20T18:30:0Z",
            "20260920T183000Z", "not-a-date", "", "Z",
            "2026-09-20T18:30:00.Z",                    // empty fraction
            "2026-09-2xT18:30:00Z",                     // non-digit
        ] {
            #expect(UsageHTTP.fastUTC(text) == nil, "fast path accepted \(text)")
            // And whatever the formatter says remains what parseDate says.
            #expect(UsageHTTP.parseDate(text) == viaFormatter(text), "parseDate diverged on \(text)")
        }
    }

    @Test("Randomised instants round-trip identically through both paths")
    func randomisedAgreement() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            // 1970 through roughly 2065.
            let seconds = Double(UInt64.random(in: 0..<3_000_000_000, using: &generator))
            let date = Date(timeIntervalSince1970: seconds)
            let text = formatter.string(from: date)
            guard let fast = UsageHTTP.fastUTC(text) else {
                Issue.record("fast path refused \(text)")
                continue
            }
            #expect(abs(fast.timeIntervalSince1970 - seconds) < 0.0005, "\(text)")
        }
    }
}

/// The single-pass marker scan must agree with the four separate scans it
/// replaced, or it silently changes which records get parsed at all.
@Suite("Transcript marker scan")
struct TranscriptMarkerTests {

    private func markers(_ text: String) -> (tools: Bool, usage: Bool, schedule: Bool) {
        Array(text.utf8).withUnsafeBufferPointer { TranscriptStats.markers(in: $0) }
    }

    @Test("Each marker is found wherever it appears")
    func findsEachMarker() {
        #expect(markers("{}") == (false, false, false))
        #expect(markers(#"{"type":"tool_use"}"#) == (true, false, false))
        #expect(markers(#"{"usage":{"input_tokens":1}}"#) == (false, true, false))
        #expect(markers(#"{"name":"ScheduleWakeup"}"#) == (false, false, true))
        #expect(markers(#"{"name":"CronCreate"}"#) == (false, false, true))
        #expect(markers(#"{"type":"tool_use","usage":{},"name":"CronCreate"}"#) == (true, true, true))
    }

    @Test("A marker split across the end of the record is not a match")
    func doesNotMatchPastTheEnd() {
        // The scan checks bounds per needle; a truncated tail must not read on.
        #expect(markers(#"{"x":"tool_us"#) == (false, false, false))
        #expect(markers(#"{"x":"usag"#) == (false, false, false))
        #expect(markers("ScheduleWakeu") == (false, false, false))
        #expect(markers("CronCreat") == (false, false, false))
        // But a complete marker right at the end is. The tool needle carries
        // its closing quote, so the bare word is not enough.
        #expect(!markers(#"x"tool_use"#).tools)
        #expect(markers(#"x"tool_use""#).tools)
        #expect(markers("xCronCreate").schedule)
    }

    @Test("Near-misses that share a first byte are refused")
    func refusesNearMisses() {
        #expect(markers(#"{"usaga":1}"#) == (false, false, false))
        // `"tool_use"` includes both quotes, so a longer name is not a match.
        #expect(!markers(#"{"type":"tool_uses_x"}"#).tools)
        #expect(markers("ScheduleWakeUp") == (false, false, false))  // capital U
        #expect(markers("CronDelete") == (false, false, false))
    }

    @Test("Empty and single-byte records are handled without reading out of bounds")
    func degenerateRecords() {
        #expect(markers("") == (false, false, false))
        #expect(markers("\"") == (false, false, false))
        #expect(markers("S") == (false, false, false))
        #expect(markers("C") == (false, false, false))
    }
}

/// The preview sheet is the app's own visual surface for the menu bar, and it
/// is how a row shape gets looked at before anyone ships it. A row shape with
/// no sample is a row shape nobody has seen.
@Suite("Menu bar preview coverage")
@MainActor
struct PreviewCoverageTests {

    @Test("The preview includes a balance row, which has no meter to judge from the others")
    func previewCoversBalances() {
        let renders = Preview.samplesForTesting()
        let balanceRows = renders.flatMap(\.rows).filter { $0.fill == nil }
        #expect(!balanceRows.isEmpty,
                "no sample exercises a row with no meter")
        // And a balance shows its figure rather than a percentage.
        #expect(balanceRows.contains { $0.percentText.contains("$") })
        // A currency without an unambiguous symbol keeps its code.
        #expect(balanceRows.contains { $0.percentText.contains("CNY") })
    }

    @Test("Every metered sample still carries a fill, so the two shapes stay distinct")
    func meteredSamplesKeepTheirFill() {
        let renders = Preview.samplesForTesting()
        let metered = renders.flatMap(\.rows).filter { $0.percentText.hasSuffix("%") }
        #expect(!metered.isEmpty)
        #expect(metered.allSatisfy { $0.fill != nil },
                "a percentage row lost its bar")
    }
}
