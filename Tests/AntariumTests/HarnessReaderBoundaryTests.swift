import Foundation
import Testing
@testable import Antarium

@Suite("Harness historical read boundaries", .serialized)
struct HarnessReaderBoundaryTests {
    private func descriptor(_ root: URL) throws -> HarnessDescriptor {
        try HarnessDocument.decode(Data("""
        {"formatVersion":1,"id":"read-fixture","name":"Fixture","process":{},
         "source":{"kind":"jsonl","path":"\(root.path)","glob":"*.jsonl"},
         "map":{"cwd":"cwd","model":"model","inputTokens":"tokens"}}
        """.utf8)).descriptor
    }
    @Test("Replacing an equal-size harness trace never reuses stale parsed facts")
    func replacement() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-read-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("trace.jsonl"), config = try descriptor(root)
        HarnessEngine.resetCaches(includingParsedFiles: true)
        try Data("{\"cwd\":\"/fixture\",\"model\":\"model-a\",\"tokens\":1}\n".utf8).write(to: file)
        #expect(HarnessEngine.sessions(config).first?.model == "model-a")
        try Data("{\"cwd\":\"/fixture\",\"model\":\"model-b\",\"tokens\":2}\n".utf8).write(to: file, options: .atomic)
        let next = try #require(HarnessEngine.sessions(config).first)
        #expect(next.model == "model-b")
        #expect(next.inputTokens == 2)
    }
    @Test("Large first reads are capped and incomplete usage is explicitly unavailable")
    func boundedHistory() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-read-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("trace.jsonl"), config = try descriptor(root)
        let line = "{\"cwd\":\"/fixture\",\"tokens\":1,\"padding\":\"" + String(repeating: "x", count: 1_000) + "\"}\n"
        try Data(String(repeating: line, count: 5_000).utf8).write(to: file)
        HarnessEngine.resetCaches(includingParsedFiles: true)
        let first = HarnessEngine.evaluate(config)
        #expect(first.metrics.bytesRead <= 4 * 1_024 * 1_024)
        #expect(first.sessions.first?.usageIssue != nil)
        let next = HarnessEngine.evaluate(config)
        #expect(next.sessions.first?.inputTokens == 5_000)
        #expect(next.sessions.first?.usageIssue == nil)
    }

    @Test("Diagnostic sampling respects its total record budget across files")
    func sampleBudget() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-sample-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5 {
            try Data(String(repeating: "{\"tokens\":1}\n", count: 20).utf8).write(to: root.appendingPathComponent("trace-\(index).jsonl"))
        }
        let sample = HarnessEngine.sampleRecords(try descriptor(root), limit: 10)
        #expect(sample.records.count <= 10)
    }
}

/// Field mappings in the middle of their range. The reader's boundaries are
/// covered above; these are the ordinary substitutions it performs, one of
/// which had nothing holding it.
@Suite("What the reader makes of the fields it is given", .serialized)
struct HarnessFieldMappingTests {

    private func session(_ record: String) throws -> HarnessEngine.Session {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data((record + "\n").utf8).write(to: root.appendingPathComponent("trace.jsonl"))
        let object: [String: Any] = [
            "formatVersion": 1, "id": "mapping-fixture", "name": "Fixture", "process": [:],
            "source": ["kind": "jsonl", "path": root.path, "glob": "*.jsonl"],
            "map": ["cwd": "cwd", "model": "model", "title": "title"]]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        HarnessEngine.resetCaches(includingParsedFiles: true)
        return try #require(HarnessEngine.sessions(descriptor).first)
    }

    @Test("A model name is taken as it is written")
    func modelIsRead() throws {
        #expect(try session(#"{"cwd":"/p","model":"synthetic-opus-5"}"#).model == "synthetic-opus-5")
    }

    /// Some harnesses write a placeholder where the model goes before one is
    /// chosen. Taking it literally puts `<none>` in the row, and sends it to
    /// the pricing table, where the longest-prefix match would answer for
    /// whatever happened to be closest.
    @Test("A placeholder in angle brackets is not a model", arguments: [
        "<none>", "<unknown>", "<default>",
    ])
    func placeholderModelsAreRefused(_ model: String) throws {
        #expect(try session(#"{"cwd":"/p","model":"\#(model)"}"#).model == nil)
    }

    @Test("An empty model is absent rather than empty")
    func emptyModel() throws {
        #expect(try session(#"{"cwd":"/p","model":""}"#).model == nil)
    }

    /// A harness that keeps the whole opening prompt in `title` would
    /// otherwise put a paragraph in a row that has one line for it.
    @Test("A multi-line title becomes its first line")
    func titleIsOneLine() throws {
        let found = try session(#"{"cwd":"/p","title":"  first line  \nsecond line\nthird"}"#)
        #expect(found.title == "first line")
    }

    @Test("A single-line title is unchanged")
    func singleLineTitle() throws {
        #expect(try session(#"{"cwd":"/p","title":"just this"}"#).title == "just this")
    }
}
