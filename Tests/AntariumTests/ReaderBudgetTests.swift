import Foundation
import SQLite3
import Testing
@testable import Antarium

/// Every reader that turns outside input into objects caps the objects, not
/// only the bytes. Three of those caps were missing and were added this week;
/// these two existed and had nothing holding them.
@Suite("Read budgets are enforced, and are not the bug")
struct ReaderBudgetTests {

    // MARK: - Cloud inventory

    private func inventory(_ count: Int, extra: [String: Any] = [:]) -> [String: Any] {
        var json: [String: Any] = ["items": (0..<count).map {
            ["id": "task-\($0)", "title": "synthetic \($0)"] as [String: Any]
        }]
        for (k, v) in extra { json[k] = v }
        return json
    }

    @Test("An inventory beyond the budget is refused rather than truncated")
    func oversizedInventory() {
        #expect(throws: CloudScan.ParseError.self) {
            _ = try CloudScan.rows(from: inventory(2_001))
        }
    }

    @Test("An inventory at the budget is still read")
    func inventoryAtTheLimit() throws {
        #expect(try CloudScan.rows(from: inventory(2_000)).count == 2_000)
    }

    /// A list that says there is more is not a short list. Reading it as one
    /// would report a subset of somebody's cloud tasks as all of them.
    @Test("A list that admits to being partial is refused", arguments: [
        ["cursor": "more"] as [String: Any],
        ["next_cursor": "more"],
        ["has_more": true],
    ])
    func partialInventories(_ extra: [String: Any]) {
        #expect(throws: CloudScan.ParseError.self) {
            _ = try CloudScan.rows(from: inventory(2, extra: extra))
        }
    }

    @Test("A list that says it is complete is read", arguments: [
        ["cursor": ""] as [String: Any],
        ["has_more": false],
        [:],
    ])
    func completeInventories(_ extra: [String: Any]) throws {
        #expect(try CloudScan.rows(from: inventory(2, extra: extra)).count == 2)
    }

    // MARK: - SQLite row budget

    private func database(rows: Int) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("fixture.sqlite").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE fixture(n);
        INSERT INTO fixture(n)
          WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < \(rows))
          SELECT x FROM c;
        """
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        return path
    }

    @Test("A query returning more rows than the budget publishes nothing")
    func oversizedQuery() throws {
        let path = try database(rows: 2_001)
        defer { try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        // Specifically the budget, not merely "some error" — this is the
        // kind of test that otherwise passes because the fixture was broken.
        #expect(throws: BoundedSQLite.ReadError.limitExceeded) {
            _ = try BoundedSQLite.query(path: path, sql: "SELECT n FROM fixture")
        }
    }

    /// The budget is a ceiling, not a default. A caller asking for more gets
    /// the ceiling, so a future reader cannot opt itself out of the bound by
    /// passing a bigger number — which is the only way this cap would ever be
    /// lost, since nothing today passes anything at all.
    @Test("A caller cannot raise the row budget above its ceiling")
    func budgetIsACeiling() throws {
        let path = try database(rows: 2_001)
        defer { try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        #expect(throws: BoundedSQLite.ReadError.limitExceeded) {
            _ = try BoundedSQLite.query(path: path, sql: "SELECT n FROM fixture",
                                        maxRows: 1_000_000)
        }
    }

    /// The budget must not be below what a real source returns, or every
    /// SQLite harness reports nothing.
    @Test("A query at the budget still returns its rows")
    func queryAtTheLimit() throws {
        let path = try database(rows: 2_000)
        defer { try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        let result = try BoundedSQLite.query(path: path, sql: "SELECT n FROM fixture")
        #expect(result.rows.count == 2_000)
    }
}
