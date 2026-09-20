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

/// The dollar figure is the number people read off the bar, and until now
/// every test of it asserted `nil` or `0` — the suite constrained when a cost
/// is unavailable and never once what it is. A rate applied to the wrong
/// field, or a per-million divisor off by a thousand, passed all of them.
@Suite("Session cost is arithmetic, not a guess")
struct TranscriptCostTests {

    /// Distinct rates against distinct token counts, so no two terms can be
    /// exchanged without changing the answer. Equal rates were how an earlier
    /// pricing test in this repo managed to pass whatever it was given.
    private static let rateA = Pricing.Rate(input: 3, output: 5, cacheWrite5m: 7,
                                            cacheWrite1h: 11, cacheRead: 13,
                                            contextWindow: 200_000)
    private static let rateB = Pricing.Rate(input: 17, output: 19, cacheWrite5m: 23,
                                            cacheWrite1h: 29, cacheRead: 31,
                                            contextWindow: 200_000)

    @Test("Every usage field is billed at its own rate, per million tokens")
    func exactCost() throws {
        var stats = TranscriptStats()
        let recorded1 = stats.recordUsage(model: "model-a", input: 1_000_000, output: 100_000,
                                  cacheWrite5m: 10_000, cacheWrite1h: 1_000, cacheRead: 100)
        #expect(recorded1)
        // 3 + 0.5 + 0.07 + 0.011 + 0.0013
        let cost = try #require(stats.estimatedCost { _ in Self.rateA })
        #expect(abs(cost - 3.5823) < 1e-9)
    }

    @Test("Each model in a session is priced at its own rate, and the totals add")
    func perModelRates() throws {
        var stats = TranscriptStats()
        let recorded2 = stats.recordUsage(model: "model-a", input: 1_000_000, output: 100_000,
                                  cacheWrite5m: 10_000, cacheWrite1h: 1_000, cacheRead: 100)
        #expect(recorded2)
        let recorded3 = stats.recordUsage(model: "model-b", input: 2_000_000, output: 0,
                                  cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(recorded3)
        let cost = try #require(stats.estimatedCost { model in
            model == "model-a" ? Self.rateA : Self.rateB
        })
        #expect(abs(cost - (3.5823 + 34.0)) < 1e-9)
    }

    @Test("One unpriced model withholds the whole total rather than under-reporting it")
    func partialPricingIsNoPricing() {
        var stats = TranscriptStats()
        let recorded4 = stats.recordUsage(model: "model-a", input: 1_000_000, output: 0,
                                  cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(recorded4)
        let recorded5 = stats.recordUsage(model: "unknown", input: 5_000_000, output: 0,
                                  cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(recorded5)
        #expect(stats.estimatedCost { $0 == "model-a" ? Self.rateA : nil } == nil)
    }

    /// `cache_creation_input_tokens` is the write total; the TTL breakdown
    /// underneath it can account for less. The remainder is billed at the
    /// five-minute rate — the cheaper of the two — so an unexplained write
    /// never inflates the estimate. Read out of the cost, where each field
    /// carries its own power of ten.
    @Test("Cache writes with no declared lifetime are billed at the cheaper rate")
    func unclassifiedCacheWrites() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let record = #"""
        {"message":{"model":"model-a","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":200,"ephemeral_1h_input_tokens":300},"cache_read_input_tokens":50}}}
        """#
        try Data((record + "\n").utf8).write(to: file)
        let stats = try #require(TranscriptStats.of(file))

        // 500 of the 1000 written tokens are unaccounted for: 5m becomes
        // 200 + 500, 1h stays at the 300 it declared.
        #expect(stats.sentTokens == 1010)        // 10 input + 1000 written
        #expect(stats.contextTokens == 1060)     // + 50 read back
        let decades = Pricing.Rate(input: 1, output: 10, cacheWrite5m: 100,
                                   cacheWrite1h: 1_000, cacheRead: 10_000,
                                   contextWindow: 200_000)
        let cost = try #require(stats.estimatedCost { _ in decades })
        // 0.00001 + 0.0002 + 0.07 + 0.3 + 0.5 — had the remainder gone to the
        // 1h bucket this would read 0.87021 - 0.05 + 0.5 instead.
        #expect(abs(cost - 0.87021) < 1e-9)
    }
}

/// `Pricing.build` drops any entry whose cache rates are incomplete, logs a
/// warning and carries on — so a model with one missing field ships showing
/// no cost at all, and the only trace is a line in the system log nobody
/// reads. These check the shipped table itself, not the arithmetic over it.
@Suite("The shipped rate table is complete and the right shape")
struct PricingTableTests {

    private struct Entry: Decodable {
        let prefix: String
        let input: Double
        let output: Double
        let cacheWrite5m: Double?
        let cacheWrite1h: Double?
        let cacheRead: Double?
        let contextWindow: Int
    }

    private func bundled() throws -> [Entry] {
        let url = try #require(AppResources.bundle.url(forResource: "pricing",
                                                       withExtension: "json"))
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        let models = try #require(object["models"])
        return try JSONDecoder().decode(
            [Entry].self, from: JSONSerialization.data(withJSONObject: models))
    }

    @Test("Every bundled model survives the build and resolves to a rate")
    func noEntryIsSilentlyDropped() throws {
        let entries = try bundled()
        #expect(entries.count > 1, "an empty table would pass everything below")
        for entry in entries {
            #expect(Pricing.rate(for: entry.prefix) != nil,
                    "\(entry.prefix) is in pricing.json but resolves to no rate")
        }
    }

    @Test("Rates have the shape a token price must have")
    func ratesAreOrdered() throws {
        for entry in try bundled() {
            let read = try #require(entry.cacheRead, "\(entry.prefix) has no cache read rate")
            let write5 = try #require(entry.cacheWrite5m, "\(entry.prefix) has no 5m write rate")
            let write1h = try #require(entry.cacheWrite1h, "\(entry.prefix) has no 1h write rate")
            #expect(entry.input > 0, "\(entry.prefix) input")
            #expect(entry.output > 0, "\(entry.prefix) output")
            #expect(entry.contextWindow > 0, "\(entry.prefix) context window")
            // Reading from cache is cheaper than sending the tokens again, and
            // writing to it costs more; an entry that breaks this is a typo or
            // a column read in the wrong order.
            #expect(read < entry.input, "\(entry.prefix): cache read is not cheaper than input")
            #expect(write5 >= entry.input, "\(entry.prefix): 5m write is not dearer than input")
            #expect(write1h >= write5, "\(entry.prefix): 1h write is cheaper than 5m")
        }
    }
}
