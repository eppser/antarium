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
    /// A harness descriptor supplies the SQL. Descriptors are trusted local
    /// configuration, but "trusted" means the app does not sandbox the author
    /// — not that a mistake or an edited file should be able to write to the
    /// database it is reading, attach another one, or load native code.
    ///
    /// This pins that behaviour. It does not pin the authorizer specifically,
    /// and it would be dishonest to claim otherwise: weakening the authorizer
    /// changes nothing observable here, because `sqlite3_stmt_readonly` already
    /// refuses every write and attach at prepare time, and `load_extension` is
    /// not a function this build exposes at all. The authorizer is a second
    /// line behind both — worth keeping for the build where one of those
    /// assumptions stops holding, and not something a test through this API
    /// can distinguish. Measured, not assumed: with the authorizer's default
    /// branch flipped to permit, all four statements still fail identically.
    @Test("The authorizer permits reading and nothing else")
    func authorizerDeniesEverythingButReads() throws {
        let file = try fixture(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        let plain = file.deletingLastPathComponent().appendingPathComponent("authz.sqlite")
        try FileManager.default.copyItem(at:file,to:plain)

        // Reading is the whole point and must keep working.
        #expect(try BoundedSQLite.query(path:plain.path,sql:"SELECT id FROM sample").rows.count == 2)
        #expect(try BoundedSQLite.query(path:plain.path,sql:"SELECT upper(id) FROM sample").rows.count == 2)

        // Loading a native extension is arbitrary code execution. SQL function
        // names are case-insensitive, so the check has to be too.
        for spelling in ["load_extension", "LOAD_EXTENSION", "Load_Extension"] {
            #expect(throws: (any Error).self) {
                try BoundedSQLite.query(path:plain.path,
                                        sql:"SELECT \(spelling)('/tmp/x.dylib')")
            }
        }

        // Writes, schema changes and attaching another database are all
        // refused: this reads somebody else's store and must leave it alone.
        for statement in ["INSERT INTO sample VALUES('three',3)",
                          "UPDATE sample SET n = 1",
                          "DELETE FROM sample",
                          "CREATE TABLE other(x)",
                          "DROP TABLE sample",
                          "ATTACH DATABASE '/tmp/other.sqlite' AS other"] {
            #expect(throws: (any Error).self, "permitted: \(statement)") {
                try BoundedSQLite.query(path:plain.path,sql:statement)
            }
        }

        // And the database really is untouched afterwards.
        #expect(try BoundedSQLite.query(path:plain.path,sql:"SELECT id FROM sample").rows.count == 2)
    }

    @Test("An over-long statement is refused before it runs")
    func sqlLengthIsBounded() throws {
        let file = try fixture(); defer { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        let plain = file.deletingLastPathComponent().appendingPathComponent("length.sqlite")
        try FileManager.default.copyItem(at:file,to:plain)
        // 65_536 is the declared ceiling; a statement past it is refused
        // rather than parsed.
        let padding = String(repeating: "a", count: 70_000)
        #expect(throws: (any Error).self) {
            try BoundedSQLite.query(path:plain.path, sql:"SELECT '\(padding)' AS id")
        }
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
