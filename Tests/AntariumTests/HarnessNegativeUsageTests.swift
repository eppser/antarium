import Foundation
import SQLite3
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

/// The same rule on the other reader. A harness whose source is SQLite goes
/// through different code from one reading JSONL, with its own sign check —
/// and only the JSONL side was held to it. Where two paths do the same job
/// and one has tests, the untested one is where the next bug lives.
@Suite("A SQLite harness cannot report negative usage either", .serialized)
struct SQLiteNegativeUsageTests {

    private func descriptor(_ root: URL, sql: String) throws -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "sqlite-negative", "name": "Fixture", "process": [:],
            "source": ["kind": "sqlite",
                       "path": root.appendingPathComponent("fixture.sqlite").path,
                       "query": sql,
                       "columns": ["cwd", "inputTokens", "outputTokens", "cost"]]]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    private func session(_ sql: String) throws -> HarnessEngine.Session {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-negative-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("fixture.sqlite").path,
                             &database) == SQLITE_OK)
        sqlite3_close(database)
        HarnessEngine.resetCaches(includingParsedFiles: true)
        return try #require(HarnessEngine.sessions(try descriptor(root, sql: sql)).first)
    }

    @Test("A negative token count is refused", arguments: [
        "SELECT '/fixture',-1,0,0",
        "SELECT '/fixture',0,-1,0",
    ])
    func negativeTokens(_ sql: String) throws {
        #expect(try session(sql).numericIssue != nil)
    }

    @Test("A negative cost is refused")
    func negativeCost() throws {
        #expect(try session("SELECT '/fixture',0,0,-0.5").numericIssue != nil)
    }

    /// And the ordinary row still reports, or the refusals above are
    /// satisfied by a reader that refuses every SQLite source.
    @Test("An ordinary row still reports its figures")
    func ordinaryRow() throws {
        let found = try session("SELECT '/fixture',120,53,1.25")
        #expect(found.numericIssue == nil)
        #expect(found.inputTokens == 120)
        #expect(found.outputTokens == 53)
        #expect(found.costUSD == 1.25)
    }

    @Test("A zero row is a measurement, not a refusal")
    func zeroRow() throws {
        let found = try session("SELECT '/fixture',0,0,0")
        #expect(found.numericIssue == nil)
        #expect(found.inputTokens == 0)
        #expect(found.costUSD == 0)
    }
}
