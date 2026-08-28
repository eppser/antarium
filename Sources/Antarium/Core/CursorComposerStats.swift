import Foundation
import SQLite3

/// Per-session facts Cursor stores in `state.vscdb`, not in agent transcripts.
///
/// Agent transcript JSONL records turns and tool calls but omits model, usage,
/// and cost. Composer rows in `cursorDiskKV` carry context occupancy,
/// bubble token totals, and the model each request used.
enum CursorComposerStats {
    struct Facts {
        var cwd: String?
        var model: String?
        var inputTokens = 0
        var outputTokens = 0
        var contextTokens: Int?
        var contextWindow: Int?
        var lastActivity: Date?

        var costUSD: Double {
            guard inputTokens > 0 || outputTokens > 0, let model else { return 0 }
            guard let rate = Pricing.rate(for: model) else { return 0 }
            return Double(inputTokens) / 1_000_000 * rate.input
                + Double(outputTokens) / 1_000_000 * rate.output
        }
    }

    static func of(sessionID: String) -> Facts? {
        guard !sessionID.isEmpty else { return nil }
        guard let database = openStateDB() else { return nil }
        defer { sqlite3_close(database) }

        var facts = Facts()
        if let composer = readComposerData(sessionID, database: database) {
            mergeComposer(composer, into: &facts)
        }
        mergeBubbles(readBubbles(sessionID: sessionID, database: database), into: &facts)

        guard facts.cwd != nil
                || facts.model != nil
                || facts.contextTokens != nil
                || facts.inputTokens > 0
                || facts.outputTokens > 0
                || facts.lastActivity != nil else { return nil }
        return facts
    }

    static func mergeComposer(_ composer: [String: Any], into facts: inout Facts) {
        if let path = workspacePath(composer) { facts.cwd = path }
        if let name = modelName(composer) {
            facts.model = normalizedModel(name, composer: composer)
        }
        if let breakdown = composer["promptTokenBreakdown"] as? [String: Any] {
            let used = intValue(breakdown["totalUsedTokens"])
            let max = intValue(breakdown["maxTokens"])
            if used > 0 { facts.contextTokens = used }
            if max > 0 { facts.contextWindow = max }
        }
        if facts.contextTokens == nil,
           let percent = doubleValue(composer["contextUsagePercent"]),
           let window = facts.contextWindow, window > 0 {
            facts.contextTokens = Int(Double(window) * percent / 100.0)
        }
        if let last = epochMillis(composer["lastUpdatedAt"])
                ?? epochMillis(composer["createdAt"]) {
            facts.lastActivity = last
        }
    }

    static func mergeBubbles(_ bubbles: [[String: Any]], into facts: inout Facts) {
        for bubble in bubbles {
            if let count = bubble["tokenCount"] as? [String: Any] {
                facts.inputTokens += intValue(count["inputTokens"])
                facts.outputTokens += intValue(count["outputTokens"])
            }
            if let name = modelName(bubble), name != "default" {
                facts.model = name
            }
        }
    }

    static func merge(sessionID: String, into session: inout HarnessEngine.Session) {
        guard let facts = of(sessionID: sessionID) else { return }
        if let cwd = facts.cwd, session.cwd == nil || session.cwd?.isEmpty == true {
            session.cwd = cwd
        }
        if let model = facts.model { session.model = model }
        if let context = facts.contextTokens, context > 0 { session.measuredContext = context }
        if let window = facts.contextWindow, window > 0 { session.contextWindow = window }
        if facts.inputTokens > 0 { session.inputTokens = facts.inputTokens }
        if facts.outputTokens > 0 { session.outputTokens = facts.outputTokens }
        let cost = facts.costUSD
        if cost > 0 { session.costUSD = cost }
        if let last = facts.lastActivity {
            if session.lastActivity == nil || last > session.lastActivity! {
                session.lastActivity = last
            }
        }
    }

  // MARK: - SQLite

    private static func openStateDB() -> OpaquePointer? {
        let path = CursorProvider.stateDBURL().path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database else { return nil }
        return database
    }

    private static func readComposerData(_ sessionID: String,
                                         database: OpaquePointer) -> [String: Any]? {
        let key = "composerData:\(sessionID)"
        guard let raw = readValue(key, database: database),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func readBubbles(sessionID: String,
                                    database: OpaquePointer) -> [[String: Any]] {
        var statement: OpaquePointer?
        let pattern = "bubbleId:\(sessionID):%"
        let query = "SELECT value FROM cursorDiskKV WHERE key LIKE ?1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bindText(pattern, to: statement, index: 1)

        var bubbles: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let text = String(cString: raw)
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            bubbles.append(object)
        }
        return bubbles
    }

    private static func readValue(_ key: String, database: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        let query = "SELECT value FROM cursorDiskKV WHERE key = ?1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(key, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    private static func normalizedModel(_ name: String, composer: [String: Any]) -> String {
        guard name == "default" else { return name }
        if composer["unifiedMode"] as? String == "agent" { return "auto" }
        return name
    }

    private static func bindText(_ text: String, to statement: OpaquePointer, index: Int32) {
        _ = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private static func workspacePath(_ composer: [String: Any]) -> String? {
        guard let identifier = composer["workspaceIdentifier"] as? [String: Any],
              let uri = identifier["uri"] as? [String: Any],
              let path = uri["fsPath"] as? String, !path.isEmpty else { return nil }
        return path
    }

    private static func modelName(_ object: [String: Any]) -> String? {
        if let info = object["modelInfo"] as? [String: Any],
           let name = info["modelName"] as? String, !name.isEmpty { return name }
        if let config = object["modelConfig"] as? [String: Any] {
            if let name = config["modelName"] as? String, !name.isEmpty { return name }
            if let selected = config["selectedModels"] as? [[String: Any]],
               let first = selected.first,
               let id = first["modelId"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int {
        switch value {
        case let number as Int: return number
        case let number as Double: return Int(number)
        case let number as Int64: return Int(number)
        case let text as String:
            return Int(text) ?? 0
        default: return 0
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let text as String: return Double(text)
        default: return nil
        }
    }

    private static func epochMillis(_ value: Any?) -> Date? {
        guard let millis = doubleValue(value) else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
