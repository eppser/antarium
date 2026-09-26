import Foundation
import Testing
@testable import Antarium

/// One reply, written several times over.
///
/// Claude Code writes a record per content block while a reply streams —
/// thinking, text, each tool call — and every one repeats the whole of
/// `message.usage`. Adding the records up adds the same reply up several
/// times. Other readers of these files report totals inflated by about four
/// times for this reason, and all of them key on `message.id` with
/// `requestId` to stop it.
///
/// This app summed every record. The figures on a Claude row — tokens sent,
/// tokens received, and the cost derived from them — were larger than the
/// reply they describe, by however many blocks it happened to contain.
@Suite("A streamed reply is counted once", .serialized)
struct UsageDeduplicationTests {

    /// One record, as Claude Code writes them.
    private func record(messageID: String?, requestID: String?, input: Int, output: Int,
                        tools: Int = 0, at stamp: String = "2026-09-25T10:00:00.000Z")
        -> String {
        var message: [String: Any] = [
            "role": "assistant",
            "model": "claude-fable-5-1",
            "usage": ["input_tokens": input, "output_tokens": output,
                      "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0],
        ]
        if let messageID { message["id"] = messageID }
        if tools > 0 {
            message["content"] = (0..<tools).map { ["type": "tool_use", "name": "Bash\($0)"] }
        }
        var line: [String: Any] = ["type": "assistant", "message": message, "timestamp": stamp]
        if let requestID { line["requestId"] = requestID }
        return String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }

    private func stats(_ lines: [String]) throws -> TranscriptStats {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dedup-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try #require(TranscriptStats.of(url))
    }

    /// The defect. Three records, one reply.
    @Test("A reply streamed across three records is counted once")
    func streamedReplyCountedOnce() throws {
        let streamed = (0..<3).map { _ in
            record(messageID: "msg_01", requestID: "req_01", input: 1_000, output: 200)
        }
        let one = try stats([streamed[0]])
        let three = try stats(streamed)
        #expect(three.sentTokens == one.sentTokens,
                Comment(rawValue: "three records of one reply reported \(three.sentTokens) sent "
                        + "against \(one.sentTokens) for the same reply written once"))
        #expect(three.receivedTokens == one.receivedTokens,
                Comment(rawValue: "three records reported \(three.receivedTokens) received"))
    }

    /// And the part that must not be deduplicated with it: the records differ
    /// in their content, so their tool calls are separate work. Counting the
    /// reply once must not count its tools once.
    @Test("The tool calls in those records are still all counted")
    func toolCallsAreNotDeduplicated() throws {
        let streamed = [
            record(messageID: "msg_01", requestID: "req_01", input: 1_000, output: 200, tools: 1),
            record(messageID: "msg_01", requestID: "req_01", input: 1_000, output: 200, tools: 2),
        ]
        let read = try stats(streamed)
        #expect(read.toolCalls == 3,
                Comment(rawValue: "\(read.toolCalls) tool calls across records of one reply"))
    }

    /// Two genuine replies are two replies. Without this the fix could be
    /// "count the first record and stop", which would report one reply for a
    /// whole conversation.
    @Test("Separate replies are counted separately")
    func separateRepliesBothCount() throws {
        let two = try stats([
            record(messageID: "msg_01", requestID: "req_01", input: 1_000, output: 200),
            record(messageID: "msg_02", requestID: "req_02", input: 1_000, output: 200),
        ])
        let one = try stats([record(messageID: "msg_01", requestID: "req_01",
                                    input: 1_000, output: 200)])
        #expect(two.sentTokens == one.sentTokens * 2,
                Comment(rawValue: "two replies reported \(two.sentTokens) against "
                        + "\(one.sentTokens) for one"))
    }

    /// The same message id under a different request is a different reply —
    /// which is why the key is the pair and not the message alone.
    @Test("A repeated message id under a new request is a new reply")
    func requestIdSeparatesReplies() throws {
        let both = try stats([
            record(messageID: "msg_01", requestID: "req_01", input: 500, output: 100),
            record(messageID: "msg_01", requestID: "req_02", input: 500, output: 100),
        ])
        let single = try stats([record(messageID: "msg_01", requestID: "req_01",
                                       input: 500, output: 100)])
        #expect(both.sentTokens == single.sentTokens * 2)
    }

    /// A record naming neither is counted, because it cannot be paired with
    /// anything and under-reporting real work is the worse mistake.
    @Test("A record identifying nothing is still counted")
    func unidentifiedRecordsCount() throws {
        let two = try stats([
            record(messageID: nil, requestID: nil, input: 700, output: 70),
            record(messageID: nil, requestID: nil, input: 700, output: 70),
        ])
        let one = try stats([record(messageID: nil, requestID: nil, input: 700, output: 70)])
        #expect(two.sentTokens == one.sentTokens * 2)
        #expect(TranscriptStats.usageKey(message: [:], record: [:]) == nil)
    }

    /// And the key is the pair, so neither half alone decides it.
    @Test("The key is both halves")
    func keyUsesBothHalves() {
        let a = TranscriptStats.usageKey(message: ["id": "m"], record: ["requestId": "r"])
        let b = TranscriptStats.usageKey(message: ["id": "m"], record: ["requestId": "r2"])
        let c = TranscriptStats.usageKey(message: ["id": "m2"], record: ["requestId": "r"])
        #expect(a != nil && a != b && a != c && b != c)
        #expect(TranscriptStats.usageKey(message: ["id": "m"], record: [:]) != nil,
                "a record with an id and no request can still be paired")
    }
}
