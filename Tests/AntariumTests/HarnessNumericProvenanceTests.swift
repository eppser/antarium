import Foundation
import Testing
@testable import Antarium

@Suite("Harness numeric failure provenance", .serialized)
struct HarnessNumericProvenanceTests {
    @Test("Invalid usage values remain an explicit issue rather than becoming zero usage")
    func invalidUsage() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("numeric-harness-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("trace.jsonl")
        try Data("{\"cwd\":\"/fixture\",\"input\":\"nan\"}\n".utf8).write(to: file)
        let descriptor = try HarnessDocument.decode(Data("""
        {"formatVersion":1,"id":"numeric-fixture","name":"Fixture","process":{},
         "source":{"kind":"jsonl","path":"\(root.path)","glob":"*.jsonl"},
         "map":{"cwd":"cwd","inputTokens":"input"}}
        """.utf8)).descriptor
        HarnessEngine.resetCaches(includingParsedFiles: true)
        let session = try #require(HarnessEngine.sessions(descriptor).first)
        #expect(session.usageIssue != nil)
        var row = AgentRow(id: "fixture", agentID: "fixture", name: "Fixture", cwd: "/fixture", state: .waiting)
        AgentScan.apply(session, to: &row, descriptor, processAlive: true)
        #expect(row.sentTokens == nil)
        #expect(row.costUSD == nil)
        #expect(row.note?.contains("unavailable") == true)
    }
    @Test("Combined usage counters cannot overflow into a crash or a fabricated total")
    func combinedOverflow() {
        var session = HarnessEngine.Session()
        session.inputTokens = Int.max
        session.cacheWrite = 1
        #expect(session.sentTokens == nil)
        #expect(session.usageIssue != nil)
    }
}
