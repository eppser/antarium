import Foundation
import SQLite3
import Testing
@testable import Antarium

@Suite("Measured zero versus absent harness metrics", .serialized)
struct HarnessZeroValueTests {
    private func descriptor(_ root:URL,sql:String? = nil) throws -> HarnessDescriptor {
        let source:[String:Any] = sql.map { ["kind":"sqlite","path":root.appendingPathComponent("fixture.sqlite").path,
            "query":$0,"columns":["cwd","inputTokens","outputTokens","cost","contextTokens","toolCalls","turns","subAgents"]] }
            ?? ["kind":"jsonl","path":root.path,"glob":"*.jsonl"]
        let object:[String:Any] = ["formatVersion":1,"id":"zero-fixture","name":"Fixture","process":[:],"source":source,
            "map":["cwd":"cwd","inputTokens":"input","outputTokens":"output","cost":"cost",
                "contextTokens":["context"],"toolCalls":["path":"tools"],"turns":["path":"turns"],"subAgents":["path":"agents"]]]
        return try HarnessDocument.decode(JSONSerialization.data(withJSONObject:object)).descriptor
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zero-metrics-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func row(_ descriptor:HarnessDescriptor) throws -> AgentRow {
        HarnessEngine.resetCaches()
        let session = try #require(HarnessEngine.sessions(descriptor).first)
        var row = AgentRow(id:"fixture",agentID:"fixture",name:"Fixture",cwd:"/fixture",state:.waiting)
        AgentScan.apply(session,to:&row,descriptor,processAlive:true)
        return row
    }
    @Test("Explicit JSON zero counters stay visible, while missing fields remain unavailable")
    func jsonZeros() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("trace.jsonl")
        try Data(#"{"cwd":"/fixture","input":0,"output":0,"cost":0,"context":0,"tools":[],"turns":[],"agents":[]}"#.appending("\n").utf8).write(to:file)
        let descriptor = try descriptor(root), measured = try row(descriptor)
        #expect(measured.sentTokens == 0); #expect(measured.receivedTokens == 0)
        #expect(measured.costUSD == 0); #expect(measured.contextTokens == 0)
        #expect(measured.toolCalls == 0); #expect(measured.turns == 0); #expect(measured.subAgents == 0)
        try Data(#"{"cwd":"/fixture"}"#.appending("\n").utf8).write(to:file,options:.atomic)
        let absent = try row(descriptor)
        #expect(absent.sentTokens == nil); #expect(absent.receivedTokens == nil)
        #expect(absent.costUSD == nil); #expect(absent.contextTokens == nil)
        #expect(absent.toolCalls == nil); #expect(absent.turns == nil); #expect(absent.subAgents == nil)
        try Data(#"{"cwd":"/fixture","input":null,"output":null,"cost":null,"context":null}"#.appending("\n").utf8).write(to:file,options:.atomic)
        let null = try row(descriptor)
        #expect(null.sentTokens == nil); #expect(null.costUSD == nil); #expect(null.note == nil)
    }
    @Test("SQLite NULL and zero retain different meanings after mapping to a session row")
    func sqliteZeros() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        var db:OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("fixture.sqlite").path,&db) == SQLITE_OK)
        #expect(sqlite3_exec(db,"CREATE TABLE fixture(n);",nil,nil,nil) == SQLITE_OK)
        sqlite3_close(db)
        let measured = try row(descriptor(root,sql:"SELECT '/fixture',0,0,0,0,0,0,0"))
        #expect(measured.sentTokens == 0); #expect(measured.receivedTokens == 0)
        #expect(measured.costUSD == 0); #expect(measured.contextTokens == 0)
        #expect(measured.toolCalls == 0); #expect(measured.turns == 0); #expect(measured.subAgents == 0)
        let absent = try row(descriptor(root,sql:"SELECT '/fixture',NULL,NULL,NULL,NULL,NULL,NULL,NULL"))
        #expect(absent.sentTokens == nil); #expect(absent.receivedTokens == nil)
        #expect(absent.costUSD == nil); #expect(absent.contextTokens == nil)
        #expect(absent.toolCalls == nil); #expect(absent.turns == nil); #expect(absent.subAgents == nil)
    }
    @Test("Malformed SQLite counts do not silently coerce into numeric zero")
    func sqliteInvalid() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        var db:OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("fixture.sqlite").path,&db) == SQLITE_OK)
        #expect(sqlite3_exec(db,"CREATE TABLE fixture(n);",nil,nil,nil) == SQLITE_OK)
        sqlite3_close(db)
        let value = try row(descriptor(root,sql:"SELECT '/fixture','not-a-number',0,0,0,0,0,0"))
        #expect(value.note?.contains("unavailable") == true)
        #expect(value.sentTokens == nil)
    }
}
