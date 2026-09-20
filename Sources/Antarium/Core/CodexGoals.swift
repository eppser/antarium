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
    private struct Cached {
        let fingerprint:String
        let checked:TimeInterval
        let result:Result<[String:Goal],ReadError>
    }
    nonisolated(unsafe) private static var cache:[String:Cached] = [:]
    private static let lock = NSLock()

    static func all(at path:String) throws -> [String:Goal] {
        let url = URL(fileURLWithPath:path.expandingTilde)
        let fingerprint = ["", "-wal", "-shm"].map {
            FileStamp.of(URL(fileURLWithPath:url.path + $0))
        }.joined(separator:"|")
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if let hit = cache[url.path], hit.fingerprint == fingerprint {
            let reusable:Bool
            switch hit.result {
            case .success: reusable = true
            case .failure: reusable = now >= hit.checked && now - hit.checked < 5
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
        if cache[url.path] == nil, cache.count >= 32, let victim = cache.keys.first { cache.removeValue(forKey:victim) }
        cache[url.path] = Cached(fingerprint:fingerprint,checked:now,result:result)
        lock.unlock()
        return try result.get()
    }
}
