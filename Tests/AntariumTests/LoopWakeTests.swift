import Foundation
import Testing
@testable import Antarium

/// When a looping agent says it will wake.
///
/// Read from a `ScheduleWakeup` or `CronCreate` tool call in the transcript. The
/// delay reached `as? Double`, which takes a boolean `NSNumber` as 1 — so
/// `"delaySeconds": true` said the agent wakes in one second, on a row whose whole
/// purpose is to say when it wakes. The branch beside it already had the honest
/// answer for a delay that cannot be read: record that a loop exists without
/// claiming a time.
///
/// Found by sweeping the whole tree for numeric coercions, after the sweep for them
/// in the providers alone turned out to be wrong.
@Suite("A loop's wake time is read, or is honestly absent", .serialized)
struct LoopWakeTests {

    /// One transcript holding one scheduling call.
    private func stats(_ input: String, name: String = "ScheduleWakeup") throws
        -> TranscriptStats? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = #"""
        {"timestamp":"2026-09-27T12:00:00Z","message":{"content":[
          {"type":"tool_use","name":"\#(name)","input":\#(input)}]}}
        """#.replacingOccurrences(of: "\n", with: "")
        let file = root.appendingPathComponent("session.jsonl")
        try Data((line + "\n").utf8).write(to: file)
        return TranscriptStats.of(file)
    }

    /// The line's own timestamp, parsed by the same reader the code uses rather
    /// than written as an epoch. My first attempt hardcoded one and was two days
    /// out, which made every case fail by exactly 172800 seconds — a number that
    /// says "your constant is wrong", not "the code is".
    private var stamp: Date {
        UsageHTTP.parseDate("2026-09-27T12:00:00Z") ?? .distantPast
    }

    @Test("A real delay is read as a time")
    func realDelay() throws {
        let stats = try #require(try stats(#"{"delaySeconds":1800}"#))
        let wake = try #require(stats.loopWakeAt)
        #expect(abs(wake.timeIntervalSince(stamp) - 1800) < 1,
                Comment(rawValue: "woke \(wake.timeIntervalSince(stamp))s after the line"))
    }

    /// The defect: one second, from a flag.
    @Test("A delay stated as a flag is not a one-second wake", arguments: ["true", "false"])
    func flagDelay(literal: String) throws {
        let stats = try #require(try stats(#"{"delaySeconds":\#(literal)}"#))
        let wake = try #require(stats.loopWakeAt,
                                "a loop with an unreadable delay should still be a loop")
        #expect(abs(wake.timeIntervalSince(stamp)) < 1,
                Comment(rawValue: "delaySeconds: \(literal) put the wake "
                        + "\(wake.timeIntervalSince(stamp))s out — a flag was read as a delay"))
    }

    /// And every other unreadable delay lands the same way: the loop is recorded,
    /// the time is not invented.
    @Test("An unreadable delay records the loop without a time", arguments: [
        #"{"delaySeconds":"1800"}"#, #"{"delaySeconds":-1}"#,
        #"{"delaySeconds":1e30}"#, #"{"delaySeconds":null}"#, "{}",
    ])
    func unreadableDelay(input: String) throws {
        let stats = try #require(try stats(input))
        let wake = try #require(stats.loopWakeAt)
        #expect(abs(wake.timeIntervalSince(stamp)) < 1,
                Comment(rawValue: "\(input) produced a wake \(wake.timeIntervalSince(stamp))s out"))
    }

    /// A stop is a stop, and it clears the time rather than leaving a stale one.
    @Test("A stopped loop has no wake time")
    func stopped() throws {
        let stats = try #require(try stats(#"{"stop":true}"#))
        #expect(stats.loopStopped)
        #expect(stats.loopWakeAt == nil)
    }

    /// A cron loop has no single next time, which the code says outright — so it
    /// records that one exists rather than a time it cannot know.
    @Test("A cron loop is a loop with no stated time")
    func cron() throws {
        let stats = try #require(try stats("{}", name: "CronCreate"))
        #expect(!stats.loopStopped)
        #expect(stats.loopWakeAt != nil, "a cron loop read as no loop at all")
    }

    /// A tool call that is not a scheduling one changes nothing, or every
    /// transcript would look like a loop.
    @Test("Another tool call is not a loop")
    func otherTool() throws {
        let stats = try #require(try stats(#"{"delaySeconds":1800}"#, name: "Bash"))
        #expect(stats.loopWakeAt == nil,
                "an unrelated tool call was read as a scheduled loop")
    }
}
