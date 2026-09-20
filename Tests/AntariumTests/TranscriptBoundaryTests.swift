import Foundation
import Testing
@testable import Antarium

@Suite("Transcript cache and numeric boundaries")
struct TranscriptBoundaryTests {
    private func record(_ model: String, input: String = "1") -> Data {
        Data("{\"message\":{\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":1}}}\n".utf8)
    }
    @Test("Same-size atomic replacement invalidates previously parsed transcript facts")
    func replacement() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try record("model-a").write(to: file)
        #expect(TranscriptStats.of(file)?.model == "model-a")
        try record("model-b").write(to: file, options: .atomic)
        #expect(TranscriptStats.of(file)?.model == "model-b")
        #expect(TranscriptStats.of(file)?.sentTokens == 1)
    }
    @Test("Negative usage cannot become a negative token total")
    func negativeUsage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try record("model-a", input: "-12").write(to: file)
        #expect((TranscriptStats.of(file)?.sentTokens ?? -1) >= 0)
    }

    @Test("Missing pricing is unavailable rather than a fabricated zero estimate")
    func missingPrice() {
        var stats = TranscriptStats()
        stats.recordUsage(model: "unknown", input: 12, output: 5, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(stats.estimatedCost { _ in nil } == nil)
    }
    @Test("Tool counts use JSON structure, independent of whitespace or quoted text")
    func structuralTools() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let record = #"{"message":{"content":[{"type": "tool_use", "name":"Read","input":{}},{"type":"text","text":"example tool_use text"}]}}"#
        try Data((record + "\n").utf8).write(to: file)
        #expect(TranscriptStats.of(file)?.toolCalls == 1)
    }
    @Test("Overflow and nonfinite usage cannot trap or become valid statistics")
    func unsafeUsage() throws {
        var stats = TranscriptStats()
        let first = stats.recordUsage(model: "unknown", input: Int.max, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(first)
        let next = stats.recordUsage(model: "unknown", input: 1, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(!next)
        #expect(stats.usageIssue != nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try record("unknown", input: "1e300").write(to: file)
        #expect(TranscriptStats.of(file)?.usageIssue != nil)
    }
    @Test("Required usage fields are never silently replaced by zero", arguments:[
        #"{"input_tokens":1}"#, #"{"output_tokens":1}"#, "{}",
        #"{"input_tokens":true,"output_tokens":1}"#,
        #"{"input_tokens":1,"output_tokens":1,"cache_creation":"invalid"}"#,
        #"{"input_tokens":1,"output_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":1}}"#
    ])
    func incompleteUsage(_ usage:String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-incomplete-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at:file) }
        try Data(("{\"message\":{\"usage\":" + usage + "}}\n").utf8).write(to:file)
        let stats = try #require(TranscriptStats.of(file))
        #expect(stats.usageIssue != nil)
        #expect(stats.contextTokens == nil)
        var row = AgentRow(id:"fixture",agentID:"fixture",name:"Synthetic",cwd:"",state:.unobserved)
        AgentScan.applyTranscript(stats,to:&row)
        #expect(row.sentTokens == nil)
        #expect(row.receivedTokens == nil)
    }
    @Test("Observed zero totals remain distinct from missing transcript usage")
    func zeroVersusAbsent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-zero-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at:file) }
        try Data(#"{"message":{"usage":{"input_tokens":0,"output_tokens":0}}}"#.utf8).write(to:file)
        let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd(); try handle.write(contentsOf:Data([10])); try handle.close()
        let stats = try #require(TranscriptStats.of(file))
        var row = AgentRow(id:"fixture",agentID:"fixture",name:"Synthetic",cwd:"",state:.unobserved)
        AgentScan.applyTranscript(stats,to:&row)
        #expect(row.sentTokens == 0)
        #expect(row.receivedTokens == 0)
        AgentScan.applyTranscript(TranscriptStats(),to:&row)
        #expect(row.sentTokens == nil)
        #expect(row.receivedTokens == nil)
    }
    @Test("A usage record without a model cannot inherit an earlier model's price")
    func missingModelPrice() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-price-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at:file) }
        try (record("synthetic-model") + Data(#"{"message":{"usage":{"input_tokens":1,"output_tokens":1}}}"#.utf8) + Data([10])).write(to:file)
        let stats = try #require(TranscriptStats.of(file))
        #expect(stats.estimatedCost { model in
            model == "synthetic-model" ? Pricing.Rate(input:1,output:1,cacheWrite5m:1,cacheWrite1h:1,cacheRead:1,contextWindow:100) : nil
        } == nil)
    }

}
