import Foundation
import SQLite3
import Testing
@testable import Antarium

@Suite("Autonomous goal observation")
struct GoalObservationTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-observation-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func database(_ file:URL,sql:String = "INSERT INTO thread_goals VALUES('synthetic','Synthetic objective','active',0,NULL)") throws {
        var db:OpaquePointer?
        #expect(sqlite3_open(file.path,&db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db,"CREATE TABLE thread_goals(thread_id TEXT, objective TEXT, status TEXT, tokens_used INTEGER, token_budget INTEGER); " + sql,nil,nil,nil) == SQLITE_OK)
    }
    @Test("Missing, malformed and symlinked databases are unavailable, not successful empty inventories")
    func failures() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("goals.sqlite")
        #expect(throws:(any Error).self) { _ = try CodexGoals.all(at:file.path) }
        try Data("not a database".utf8).write(to:file)
        #expect(throws:(any Error).self) { _ = try CodexGoals.all(at:file.path) }
        try FileManager.default.removeItem(at:file)
        let target = root.appendingPathComponent("target.sqlite"); try database(target)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
        #expect(throws:(any Error).self) { _ = try CodexGoals.all(at:file.path) }
    }
    @Test("SQLite punctuation in a filename does not change the database being observed")
    func literalFilename() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("goals?synthetic.sqlite"); try database(file)
        #expect(try CodexGoals.all(at:file.path)["synthetic"]?.isRunning == true)
    }
    @Test("Goal capacity and incomplete identity/status rows cannot publish partial success")
    func invalidInventory() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let cases = ["INSERT INTO thread_goals VALUES('synthetic','Synthetic',NULL,0,NULL)",
                     "INSERT INTO thread_goals VALUES('synthetic','Synthetic','future-state',0,NULL)",
                     "INSERT INTO thread_goals VALUES('same','Synthetic','active',0,NULL),('same','Synthetic','complete',0,NULL)",
                     "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<2001) INSERT INTO thread_goals SELECT x,'Synthetic','active',0,NULL FROM n"]
        for (index,sql) in cases.enumerated() {
            let file = root.appendingPathComponent("goals-\(index).sqlite"); try database(file,sql:sql)
            #expect(throws:(any Error).self) { _ = try CodexGoals.all(at:file.path) }
        }
    }
    @Test("Unavailable loop state cannot turn a quiet agent into a confirmed waiting agent")
    func unavailableLoopState() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let payload:[String:Any] = ["formatVersion":1,"id":"fixture","name":"Synthetic","process":[:],
            "source":["kind":"none","path":"","paths":["goals":root.appendingPathComponent("missing.sqlite").path]]]
        let descriptor = try HarnessDocument.decode(JSONSerialization.data(withJSONObject:payload)).descriptor
        var session = HarnessEngine.Session(); session.sessionID = "synthetic"
        session.lastActivity = Date(timeIntervalSince1970:100)
        var row = AgentRow(id:"fixture",agentID:"fixture",name:"Synthetic",cwd:"",state:.working)
        AgentScan.apply(session,to:&row,descriptor,processAlive:true)
        #expect(row.state.label == "Unknown")
        #expect(row.note?.contains("goal") == true)
        let firstIssue = row.note
        AgentScan.apply(session,to:&row,descriptor,processAlive:true)
        #expect(row.note == firstIssue)
        row.loopWakeAt = Date().addingTimeInterval(60)
        AgentScan.apply(session,to:&row,descriptor,processAlive:true)
        #expect(row.state.label == "Looping")
        row.loopWakeAt = nil
        session.isWorking = true
        AgentScan.apply(session,to:&row,descriptor,processAlive:true)
        #expect(row.state.label == "Working")
        AgentScan.apply(session,to:&row,descriptor,processAlive:false)
        #expect(row.state.label == "Ended")
        try database(root.appendingPathComponent("missing.sqlite"))
        session.isWorking = false
        AgentScan.apply(session,to:&row,descriptor,processAlive:true)
        #expect(row.state.label == "Looping")
        #expect(row.note == nil)
    }
}
