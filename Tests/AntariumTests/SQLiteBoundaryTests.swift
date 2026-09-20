import Foundation
import SQLite3
import Darwin
import Testing
@testable import Antarium

@Suite("Bounded read-only SQLite sources", .serialized)
struct SQLiteBoundaryTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-boundary-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file = root.appendingPathComponent("fixture #?&.sqlite")
        var db:OpaquePointer?
        guard sqlite3_open(file.path,&db) == SQLITE_OK, let db else { throw NSError(domain:"fixture",code:1) }
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db,"CREATE TABLE sample(id TEXT,n INTEGER); INSERT INTO sample VALUES('one',0),('two',NULL);",nil,nil,nil) == SQLITE_OK)
        return file
    }
    private func selection(_ file:URL,query:String,column:String = "id") throws -> HarnessDescriptor.Selection? {
        let object:[String:Any] = ["formatVersion":1,"id":"sqlite-fixture","name":"Fixture","process":[:],
            "source":["kind":"none","path":""],
            "selection":["kind":"sqlite","path":file.path,"query":query,"column":column]]
        return try HarnessDocument.decode(JSONSerialization.data(withJSONObject:object)).descriptor.sessionSelection
    }
    @Test("A malformed SQLite row expression is unavailable, not an empty set of open sessions")
    func steppingError() throws {
        let file = try fixture(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        // Use an uncomplicated alias so the pre-existing URI bug does not hide
        // the step-error regression behind an unrelated open failure.
        let plain = file.deletingLastPathComponent().appendingPathComponent("plain.sqlite")
        try FileManager.default.copyItem(at:file,to:plain)
        #expect(SessionSelection.openIDs(try selection(plain,query:"SELECT json_extract('broken','$') AS id")) == nil)
        #expect(SessionSelection.openIDs(try selection(plain,query:"SELECT id FROM sample WHERE 0")) == [])
        #expect(SessionSelection.openIDs(try selection(plain,query:"SELECT id FROM sample",column:"missing")) == nil)
        #expect(SessionSelection.openIDs(try selection(plain,query:"SELECT NULL AS id")) == nil)
        #expect(SessionSelection.openIDs(try selection(plain,query:"SELECT id AS id,n AS id FROM sample")) == nil)
    }
    @Test("Database path punctuation is literal and SQL NULL stays distinct from numeric zero")
    func literalAndNull() throws {
        let file = try fixture(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        let result = try BoundedSQLite.query(path:file.path,sql:"SELECT id,n FROM sample ORDER BY id")
        #expect(result.columns == ["id","n"])
        #expect(result.rows.count == 2)
        #expect(result.rows[0][1] == .integer(0))
        #expect(result.rows[1][1] == .null)
        #expect(SessionSelection.openIDs(try selection(file,query:"SELECT id FROM sample")) == ["one","two"])
    }
    @Test("Row, cell and execution limits reject partial results explicitly")
    func limits() throws {
        let file = try fixture(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        #expect(try BoundedSQLite.query(path:file.path,sql:"SELECT id FROM sample").rows.count == 2)
        #expect(throws:(any Error).self) {
            try BoundedSQLite.query(path:file.path,sql:"WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<3000) SELECT n FROM x")
        }
        #expect(throws:(any Error).self) {
            try BoundedSQLite.query(path:file.path,sql:"SELECT hex(zeroblob(40000))")
        }
        let began = ProcessInfo.processInfo.systemUptime
        #expect(throws:(any Error).self) {
            try BoundedSQLite.query(path:file.path,sql:"WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<1000000000) SELECT sum(n) FROM x")
        }
        #expect(ProcessInfo.processInfo.systemUptime-began < 3)
    }
    @Test("SQLite diagnostic sampling honors the requested record count")
    func diagnosticLimit() throws {
        let file = try fixture(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        let plain = file.deletingLastPathComponent().appendingPathComponent("plain.sqlite")
        try FileManager.default.copyItem(at:file,to:plain)
        let object:[String:Any] = ["formatVersion":1,"id":"sqlite-sample","name":"Fixture","process":[:],
            "source":["kind":"sqlite","path":plain.path,"query":"SELECT id FROM sample","columns":["sessionID"]]]
        let descriptor = try HarnessDocument.decode(JSONSerialization.data(withJSONObject:object)).descriptor
        #expect(HarnessEngine.sampleRecords(descriptor,limit:1).records.count == 1)
    }
    @Test("Read-only sources cannot attach, mutate, or silently ignore another statement")
    func noWrites() throws {
        let file = try fixture(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        let before = try Data(contentsOf:file)
        for sql in ["DELETE FROM sample", "ATTACH ':memory:' AS extra", "SELECT id FROM sample; SELECT n FROM sample"] {
            #expect(throws:(any Error).self) { try BoundedSQLite.query(path:file.path,sql:sql) }
        }
        #expect(try Data(contentsOf:file) == before)
    }

    @Test("A FIFO database cannot block the harness checker")
    func nonregularDatabase() throws {
        let file = try fixture(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        let root = file.deletingLastPathComponent(), fifo = root.appendingPathComponent("pipe.sqlite")
        #expect(mkfifo(fifo.path,0o600) == 0)
        let config = root.appendingPathComponent("profile.json")
        let object:[String:Any] = ["formatVersion":1,"id":"fifo-fixture","name":"Fixture","process":[:],
            "source":["kind":"sqlite","path":fifo.path,"query":"SELECT 1 AS id","columns":["sessionID"]]]
        try JSONSerialization.data(withJSONObject:object).write(to:config)
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = repository.appendingPathComponent(".build/debug/Antarium")
        // A process boundary keeps this regression bounded even if a future
        // SQLite open starts blocking again; no hung test thread is left behind.
        // The budget bounds a hang, not performance: a blocking FIFO open
        // never returns, so any finite limit catches it. Two seconds also
        // caught a loaded machine that was merely slow to launch a debug
        // binary, which is a false failure about something else entirely.
        let result = Shell.execute(executable.path,["--check",config.path],timeout:30,outputLimit:8_192)
        #expect(!result.timedOut)
        #expect(!result.cancelled)
        #expect(result.stdout.contains("SQLite") || result.stdout.contains("sqlite"))
    }
}
