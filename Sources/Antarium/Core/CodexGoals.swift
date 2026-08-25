import Foundation
import SQLite3

/// Codex's autonomous loops, read from the database it keeps them in.
///
/// A goal is Codex working toward an objective across turns without being
/// prompted each time — its own word for a loop. The row survives restarts and
/// says *why* it stopped, which no amount of watching from outside would tell
/// you: `usage_limited` and `budget_limited` are the two cases you would most
/// want to know about and the two that look exactly like "idle" from here.
enum CodexGoals {

    struct Goal {
        let threadID: String
        let objective: String
        let status: String
        let tokensUsed: Int
        let budget: Int?

        /// Only `active` is a loop still running. The rest have stopped, and
        /// saying otherwise would be a standing lie about an idle agent.
        var isRunning: Bool { status == "active" }

        /// What the row should say — the reason, when there is one worth
        /// surfacing, rather than a generic "looping".
        var label: String {
            switch status {
            case "active":         return "goal running"
            case "usage_limited":  return "goal paused — usage limit"
            case "budget_limited": return "goal paused — budget spent"
            default:               return "goal \(status)"
            }
        }
    }

    nonisolated(unsafe) private static var cache:
        [String: (fingerprint: String, goals: [String: Goal])] = [:]
    private static let lock = NSLock()

    /// Goals by thread id. Cached on the database's own timestamp: it is
    /// touched only when a goal changes, which is rare.
    static func all(at path: String) -> [String: Goal] {
        let url = URL(fileURLWithPath: path.expandingTilde)
        let fingerprint = ["", "-wal", "-shm"].map {
            let file = URL(fileURLWithPath: url.path + $0)
            return "\(file.path)=\(FileStamp.of(file))"
        }.joined(separator: "\n")
        lock.lock()
        if let cached = cache[url.path], cached.fingerprint == fingerprint {
            lock.unlock()
            return cached.goals
        }
        lock.unlock()

        var found: [String: Goal] = [:]
        var db: OpaquePointer?
        defer {
            lock.lock()
            cache[url.path] = (fingerprint, found)
            lock.unlock()
        }
        guard FileManager.default.fileExists(atPath: url.path),
              sqlite3_open_v2("file:\(url.path)?mode=ro", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            if db != nil { sqlite3_close(db) }
            return found
        }
        defer { sqlite3_close(db) }

        let query = """
        SELECT thread_id, objective, status, tokens_used, token_budget FROM thread_goals
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return found }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String {
                sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
            }
            let id = text(0)
            guard !id.isEmpty else { continue }
            found[id] = Goal(
                threadID: id,
                objective: text(1),
                status: text(2),
                tokensUsed: Int(sqlite3_column_int64(statement, 3)),
                budget: sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 4)))
        }
        return found
    }
}
