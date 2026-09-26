import Foundation

/// Reads only the goal identity and lifecycle state needed for loop indicators.
/// Objective text and budget totals are not needed and are not retained here.
enum CodexGoals {
    struct Goal {
        let threadID: String
        let status: String
        var isRunning: Bool { status == "active" }
        var label: String {
            switch status {
            case "active": return "goal running"
            case "usage_limited": return "goal paused — usage limit"
            case "budget_limited": return "goal paused — budget spent"
            default: return "goal stopped or paused"
            }
        }
    }
    enum ReadError: Error {
        case source(BoundedSQLite.ReadError), invalidInventory
        var message:String {
            switch self {
            case .source(let error): return "Autonomous goal state is unavailable. " + error.message
            case .invalidInventory: return "Autonomous goal state is unavailable because its inventory is incomplete or unsupported."
            }
        }
    }
    struct Cached {
        let fingerprint:String
        let checked:TimeInterval
        let result:Result<[String:Goal],ReadError>
    }
    nonisolated(unsafe) private static var cache:[String:Cached] = [:]

    /// Which entry to drop when the cache is full.
    ///
    /// The least recently checked, not whichever the dictionary happens to
    /// yield first. An arbitrary victim is not merely non-reproducible — it
    /// can evict the entry that is about to be read again, and then do it
    /// once more next time, so a machine with enough state files never keeps
    /// the ones it uses.
    static func victim(in cache: [String: Cached], limit: Int) -> String? {
        guard cache.count >= limit else { return nil }
        return cache.min { a, b in
            a.value.checked != b.value.checked ? a.value.checked < b.value.checked
                                               : a.key < b.key
        }?.key
    }

    private static let lock = NSLock()

    static func all(at path:String) throws -> [String:Goal] {
        let url = URL(fileURLWithPath:path.expandingTilde)
        let fingerprint = ["", "-wal", "-shm"].map {
            FileStamp.of(URL(fileURLWithPath:url.path + $0))
        }.joined(separator:"|")
        lock.lock()
        // Read under the lock, not before it. Outside, a caller that waited
        // while another thread queried came back with a reading older than
        // the entry it found and judged a fresh failure stale — retrying a
        // SQLite open that had just failed, which is the whole of what this
        // five-second window exists to stop.
        let now = ProcessInfo.processInfo.systemUptime
        if let hit = cache[url.path], hit.fingerprint == fingerprint {
            let reusable:Bool
            switch hit.result {
            case .success: reusable = true
            case .failure: reusable = CacheWindow.isFresh(now: now, stamped: hit.checked, within: 5)
            }
            if reusable { lock.unlock(); return try hit.result.get() }
        }
        lock.unlock()
        let result:Result<[String:Goal],ReadError>
        do {
            let table = try BoundedSQLite.query(path:url.path,
                sql:"SELECT thread_id, status FROM thread_goals",maxRows:2_000)
            var goals:[String:Goal] = [:]
            let statuses:Set<String> = ["active","complete","completed","paused","blocked",
                "canceled","cancelled","usage_limited","budget_limited"]
            for row in table.rows {
                guard row.count == 2, case .text(let id) = row[0], !id.isEmpty, id.utf8.count <= 256,
                      case .text(let status) = row[1], statuses.contains(status), goals[id] == nil else {
                    throw ReadError.invalidInventory
                }
                goals[id] = Goal(threadID:id,status:status)
            }
            result = .success(goals)
        } catch let error as BoundedSQLite.ReadError { result = .failure(.source(error)) }
        catch let error as ReadError { result = .failure(error) }
        catch { result = .failure(.invalidInventory) }
        lock.lock()
        if cache[url.path] == nil, let victim = Self.victim(in:cache,limit:32) { cache.removeValue(forKey:victim) }
        // Stamped when stored rather than when the read began: the query is
        // the slow part, and dating the answer before it makes the window
        // shorter than it says it is.
        cache[url.path] = Cached(fingerprint:fingerprint,
                                 checked:ProcessInfo.processInfo.systemUptime,result:result)
        lock.unlock()
        return try result.get()
    }
}
