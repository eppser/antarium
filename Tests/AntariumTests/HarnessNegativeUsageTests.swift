import Foundation
import Testing
@testable import Antarium

/// A negative token count is failed data, not a small one. The transcript
/// reader has said so since "Negative usage cannot become a negative token
/// total"; the harness engine, which reads every other agent, accumulated
/// whatever it was given.
@Suite("A harness cannot report negative usage", .serialized)
struct HarnessNegativeUsageTests {

    private func descriptor(_ root: URL) throws -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "negative-fixture", "name": "Fixture", "process": [:],
            "source": ["kind": "jsonl", "path": root.path, "glob": "*.jsonl"],
            "map": ["cwd": "cwd", "inputTokens": "input", "outputTokens": "output",
                    "cacheRead": "read", "cacheWrite": "write"]]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    private func session(_ records: [String]) throws -> HarnessEngine.Session {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("negative-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(records.joined(separator: "\n").appending("\n").utf8)
            .write(to: root.appendingPathComponent("trace.jsonl"))
        HarnessEngine.resetCaches(includingParsedFiles: true)
        return try #require(HarnessEngine.sessions(try descriptor(root)).first)
    }

    /// The shape that motivated this: a later record carries a negative and
    /// silently subtracts from a total an earlier record established.
    @Test("A negative count does not reduce a total already counted")
    func negativeDoesNotSubtract() throws {
        let found = try session([
            #"{"cwd":"/fixture","input":100,"output":50,"read":0,"write":0}"#,
            #"{"cwd":"/fixture","input":-60,"output":0,"read":0,"write":0}"#,
        ])
        #expect(found.numericIssue != nil,
                "a negative usage value was accepted as arithmetic")
        #expect(found.inputTokens <= 100, "the total went backwards")
    }

    @Test("A negative in any usage field is refused", arguments: [
        #"{"cwd":"/fixture","input":-1,"output":0,"read":0,"write":0}"#,
        #"{"cwd":"/fixture","input":0,"output":-1,"read":0,"write":0}"#,
        #"{"cwd":"/fixture","input":0,"output":0,"read":-1,"write":0}"#,
        #"{"cwd":"/fixture","input":0,"output":0,"read":0,"write":-1}"#,
    ])
    func anyNegativeFieldIsRefused(_ record: String) throws {
        #expect(try session([record]).numericIssue != nil)
    }

    /// And the ordinary case still adds up, or the refusal above would be
    /// satisfied by a reader that refuses everything.
    @Test("Ordinary counts still accumulate across records")
    func ordinaryCountsAccumulate() throws {
        let found = try session([
            #"{"cwd":"/fixture","input":100,"output":50,"read":10,"write":5}"#,
            #"{"cwd":"/fixture","input":20,"output":3,"read":1,"write":2}"#,
        ])
        #expect(found.numericIssue == nil)
        #expect(found.inputTokens == 120)
        #expect(found.outputTokens == 53)
        #expect(found.cacheRead == 11)
        #expect(found.cacheWrite == 7)
    }

    @Test("A missing field contributes nothing rather than failing the read")
    func missingFieldIsZero() throws {
        let found = try session([#"{"cwd":"/fixture","input":7}"#])
        #expect(found.numericIssue == nil)
        #expect(found.inputTokens == 7)
        #expect(found.outputTokens == 0)
    }
}
