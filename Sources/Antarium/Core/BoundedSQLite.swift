import Foundation
import SQLite3
import Darwin

/// One bounded, read-only boundary for external SQLite metadata. Errors carry
/// fixed descriptions rather than SQL, database paths or private row contents.
enum BoundedSQLite {
    enum ReadError: Error, Equatable {
        case unavailable, invalidQuery, executionFailed, limitExceeded, invalidText
        var message:String {
            switch self {
            case .unavailable: return "SQLite database could not be opened read-only."
            case .invalidQuery: return "SQLite query could not be prepared as a single read-only statement."
            case .executionFailed: return "SQLite query stopped before completing. No partial result was published."
            case .limitExceeded: return "SQLite query exceeded its bounded read budget. No partial result was published."
            case .invalidText: return "SQLite query returned invalid text. No partial result was published."
            }
        }
    }
    enum Value: Equatable, Sendable {
        case null, integer(Int64), real(Double), text(String), blob(Data)
        var string: String? {
            switch self {
            case .text(let value): return value
            case .integer(let value): return String(value)
            case .real(let value): return value.isFinite ? String(value) : nil
            default: return nil
            }
        }
        var integer: Int? {
            switch self {
            case .integer(let value): return Int(exactly:value)
            case .real(let value): return value.isFinite ? Int(exactly:value) : nil
            case .text(let value): return Int(value)
            default: return nil
            }
        }
        var number: Double? {
            let result: Double?
            switch self {
            case .integer(let value): result = Double(value)
            case .real(let value): result = value
            case .text(let value): result = Double(value)
            default: result = nil
            }
            return result.flatMap { $0.isFinite ? $0 : nil }
        }
        var date: Date? {
            if case .text(let value) = self { return UsageHTTP.parseDate(value) }
            return number.flatMap(FieldPath.epoch)
        }
    }
    struct Result: Sendable {
        let columns:[String]
        let rows:[[Value]]
    }
    private final class WorkLimit {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var steps = 0
        var exceeded = false
        func shouldStop() -> Bool {
            steps += 1000
            exceeded = steps > 2_000_000 || ProcessInfo.processInfo.systemUptime >= deadline
            return exceeded
        }
    }
    static func query(path:String,sql:String,maxRows:Int = 2_000) throws -> Result {
        guard !sql.isEmpty, sql.utf8.count <= 65_536, !sql.utf8.contains(0) else { throw ReadError.invalidQuery }
        guard !path.utf8.contains(0), path.utf8.count <= 16_384 else { throw ReadError.unavailable }
        // macOS's /var and /tmp are standard symlinks. Resolve the parent
        // directory explicitly, while NOFOLLOW still rejects a symlink leaf.
        let url = URL(fileURLWithPath:path)
        guard let parent = realpath(url.deletingLastPathComponent().path,nil) else { throw ReadError.unavailable }
        // Foundation normalizes /private/var back to /var on macOS. Use the
        // native canonical path so SQLite's NOFOLLOW check remains meaningful.
        let resolved = String(cString:parent) + "/" + url.lastPathComponent
        free(parent)
        // SQLite's VFS opens filenames synchronously. Reject named pipes and
        // other special files before that open, rather than relying on a later
        // SQL progress handler which cannot interrupt filesystem open().
        var metadata = stat()
        guard lstat(resolved,&metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw ReadError.unavailable }
        var db:OpaquePointer?
        guard sqlite3_open_v2(resolved,&db,SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW,nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw ReadError.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db,250)
        sqlite3_limit(db,SQLITE_LIMIT_LENGTH,1_048_576)
        sqlite3_limit(db,SQLITE_LIMIT_SQL_LENGTH,65_536)
        sqlite3_limit(db,SQLITE_LIMIT_COLUMN,128)
        sqlite3_limit(db,SQLITE_LIMIT_EXPR_DEPTH,128)
        sqlite3_limit(db,SQLITE_LIMIT_COMPOUND_SELECT,32)
        sqlite3_set_authorizer(db,{ _,action,_,function,_,_ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE: return SQLITE_OK
            case SQLITE_FUNCTION:
                if let function, String(cString:function).lowercased() == "load_extension" { return SQLITE_DENY }
                return SQLITE_OK
            default: return SQLITE_DENY
            }
        },nil)
        let work = WorkLimit()
        sqlite3_progress_handler(db,1000,{ pointer in
            guard let pointer else { return 1 }
            return Unmanaged<WorkLimit>.fromOpaque(pointer).takeUnretainedValue().shouldStop() ? 1 : 0
        },Unmanaged.passUnretained(work).toOpaque())
        defer { sqlite3_progress_handler(db,0,nil,nil); withExtendedLifetime(work) {} }
        var statement:OpaquePointer?, trailing = ""
        let prepared = sql.withCString { text -> Int32 in
            var tail:UnsafePointer<CChar>?
            let status = sqlite3_prepare_v2(db,text,-1,&statement,&tail)
            if let tail { trailing = String(cString:tail) }
            return status
        }
        defer { if let statement { sqlite3_finalize(statement) } }
        guard prepared == SQLITE_OK, let statement, sqlite3_stmt_readonly(statement) != 0 else { throw ReadError.invalidQuery }
        if !trailing.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            var extra:OpaquePointer?
            let status = sqlite3_prepare_v2(db,trailing,-1,&extra,nil)
            let containsStatement = extra != nil
            if let extra { sqlite3_finalize(extra) }
            guard status == SQLITE_OK, !containsStatement else { throw ReadError.invalidQuery }
        }
        let count = sqlite3_column_count(statement)
        guard count > 0, count <= 128 else { throw ReadError.invalidQuery }
        let columns = (0..<count).map { String(cString:sqlite3_column_name(statement,$0)) }
        var rows:[[Value]] = [], bytes = 0
        let rowLimit = min(2_000,max(1,maxRows))
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw work.exceeded ? ReadError.limitExceeded : ReadError.executionFailed }
            guard rows.count < rowLimit else { throw ReadError.limitExceeded }
            var row:[Value] = []
            for column in 0..<count {
                let type = sqlite3_column_type(statement,column)
                let size = Int(sqlite3_column_bytes(statement,column))
                guard size <= 65_536, bytes <= 4_194_304-size else { throw ReadError.limitExceeded }
                bytes += size
                switch type {
                case SQLITE_NULL: row.append(.null)
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement,column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement,column)))
                case SQLITE_TEXT:
                    guard let pointer = sqlite3_column_text(statement,column),
                          let text = String(data:Data(bytes:pointer,count:size),encoding:.utf8) else { throw ReadError.invalidText }
                    row.append(.text(text))
                case SQLITE_BLOB:
                    if size == 0 { row.append(.blob(Data())) }
                    else if let pointer = sqlite3_column_blob(statement,column) { row.append(.blob(Data(bytes:pointer,count:size))) }
                    else { throw ReadError.invalidText }
                default: throw ReadError.invalidText
                }
            }
            rows.append(row)
        }
        return Result(columns:columns,rows:rows)
    }
}
