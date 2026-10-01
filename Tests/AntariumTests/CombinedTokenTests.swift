import Foundation
import Testing
@testable import Antarium

/// A harness that reports one token figure and no split.
///
/// docs/ECOSYSTEM.md turned one down for this: its store keeps a single
/// running count, and "this app splits sent from received on purpose" so
/// mapping the total into either half would report a number wrong in a way
/// nobody could see. That was right about the mapping and wrong about the
/// conclusion — the model simply had nowhere to put a total, which is a gap
/// here rather than a fact about that agent. Leaving it out threw away the
/// only figure such a harness has.
///
/// Driven from synthetic records in a temporary directory, so it says the
/// same thing on a Mac with nothing installed.
@Suite("A harness that reports one combined token figure", .serialized)
struct CombinedTokenTests {

    private func descriptor(_ map: [String: Any]) throws -> HarnessDescriptor {
        try HarnessDocument.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "id": "combined", "name": "Combined",
            "process": [:],
            "source": ["kind": "jsonl", "path": "/synthetic", "glob": "*.jsonl"],
            "map": map,
        ])).descriptor
    }

    /// A total and a split cannot both be believed: nothing can tell whether
    /// the total already counts the other two, so adding them makes a figure
    /// too large and ignoring them makes the declaration a lie.
    @Test("Declaring a total alongside a split is refused",
          arguments: ["inputTokens", "outputTokens", "cacheRead", "cacheWrite"])
    func totalWithSplitIsRefused(field: String) {
        #expect(throws: (any Error).self) {
            try descriptor(["totalTokens": "usage.total", field: "usage.other"])
        }
    }

    @Test("A total on its own decodes and is carried")
    func totalAloneDecodes() throws {
        let d = try descriptor(["totalTokens": "usage.total"])
        #expect(d.fields.totalTokens == "usage.total")
        #expect(d.fields.inputTokens == nil)
    }

    /// The split still decodes without a total, or the refusal above would
    /// have broken every harness that already ships.
    @Test("A split with no total is unaffected")
    func splitAloneStillDecodes() throws {
        let d = try descriptor(["inputTokens": "usage.in", "outputTokens": "usage.out"])
        #expect(d.fields.totalTokens == nil)
        #expect(d.fields.inputTokens == "usage.in")
    }

    /// End to end, through the engine: records accumulate into one figure,
    /// and the row shows it as a total rather than as half a split.
    @Test("The figure accumulates and reaches the row as a total")
    func totalReachesTheRow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("combined-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = [#"{"cwd":"/synthetic/p","usage":{"total":1200}}"#,
                     #"{"cwd":"/synthetic/p","usage":{"total":800}}"#].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: root.appendingPathComponent("s.jsonl"))

        let d = try HarnessDocument.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "id": "combined", "name": "Combined",
            "process": [:],
            "source": ["kind": "jsonl", "path": root.path, "glob": "*.jsonl"],
            "map": ["cwd": "cwd", "totalTokens": "usage.total"],
        ])).descriptor

        let session = try #require(HarnessEngine.sessions(d).first)
        #expect(session.totalTokens == 2_000, "the records did not add up")
        #expect(session.hasNumeric("totalTokens"),
                "the figure was read but not recorded as observed, so the row drops it")
        var row = AgentRow(id: "r", agentID: "combined", name: "p", cwd: "/synthetic/p",
                           state: .waiting)
        AgentScan.apply(session, to: &row, d, processAlive: true)
        #expect(row.totalTokens == 2_000, "the figure did not reach the row")
        #expect(row.sentTokens == nil && row.receivedTokens == nil,
                "a combined figure was drawn as a split as well")
        #expect(session.inputTokens == 0, "a total leaked into the sent figure")
        #expect(session.outputTokens == 0, "a total leaked into the received figure")
    }

    /// Declaring the field is not the same as finding it. The accumulator
    /// starts at nought and adds what each record carries, so a harness whose
    /// records simply do not have the field would reach the row as a
    /// confident "0 tokens" — a figure nothing ever read. This is the guard
    /// that keeps declared apart from observed.
    @Test("A total that is declared but never present is absent, not zero")
    func declaredButNeverPresent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("combined-absent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data((#"{"cwd":"/synthetic/p","note":"no usage in this record"}"# + "\n").utf8)
            .write(to: root.appendingPathComponent("s.jsonl"))

        let d = try HarnessDocument.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "id": "combined", "name": "Combined",
            "process": [:],
            "source": ["kind": "jsonl", "path": root.path, "glob": "*.jsonl"],
            "map": ["cwd": "cwd", "totalTokens": "usage.total"],
        ])).descriptor

        let session = try #require(HarnessEngine.sessions(d).first)
        #expect(session.hasNumeric("totalTokens") == false,
                "a field that never appeared was recorded as observed")
        // Through the real function rather than a copy of its line: a test
        // that restates the rule agrees with itself whatever the code does,
        // which is how the first version of this passed while the guard it
        // was written for could be deleted.
        var row = AgentRow(id: "r", agentID: "combined", name: "p", cwd: "/synthetic/p",
                           state: .waiting)
        AgentScan.apply(session, to: &row, d, processAlive: true)
        #expect(row.totalTokens == nil, "the row showed a figure nothing read")
    }

    /// A harness that maps no total reports none — absent, not zero, which is
    /// what keeps "reports one figure" apart from "reports nothing".
    @Test("A harness that maps no total reports none")
    func noTotalIsAbsent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("combined-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data((#"{"cwd":"/synthetic/p","usage":{"in":10}}"# + "\n").utf8)
            .write(to: root.appendingPathComponent("s.jsonl"))

        let d = try HarnessDocument.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "id": "combined", "name": "Combined",
            "process": [:],
            "source": ["kind": "jsonl", "path": root.path, "glob": "*.jsonl"],
            "map": ["cwd": "cwd", "inputTokens": "usage.in"],
        ])).descriptor

        let session = try #require(HarnessEngine.sessions(d).first)
        #expect(session.totalTokens == nil)
        #expect(session.hasNumeric("totalTokens") == false)
    }
}
