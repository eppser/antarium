import Foundation
import CoreFoundation

/// Experimental Codex cloud task discovery.
///
/// `GET chatgpt.com/backend-api/wham/tasks` is authenticated with the same
/// credentials as the usage endpoint and returns `{ items: [...], cursor }`.
/// **The item shape is unverified**: the account had no cloud tasks running
/// when this was written, so the field names below are read defensively and a
/// incomplete or unrecognized inventory is rejected rather than guessed at.
enum CloudScan {
    enum ParseError: Error {
        case missingItems, malformedItem, duplicateIdentity, incompleteInventory, invalidDate, capacityExceeded
    }

    /// Longest vendor string that reaches a row. The same 64 the descriptor
    /// providers, Codex and Gemini all bound their response text to, for the
    /// same reason: it is drawn in a menu, not stored.
    static let maxText = 64

    private static let session = UsageHTTP.makeSession(headers: [
        "User-Agent": "Antarium/1.0 (macOS menu bar)",
        "Accept": "application/json",
    ])

    static func codexTasks(auth: (token: String, accountID: String?)? = CodexProvider.storedAuth()) async throws -> [AgentRow] {
        guard let auth, !auth.token.isEmpty else { throw ProviderError.notConfigured("Cloud task credentials are unavailable.") }
        var headers = ["Authorization": "Bearer \(auth.token)"]
        if let account = auth.accountID { headers["ChatGPT-Account-Id"] = account }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/tasks")
        else { throw URLError(.badURL) }
        let json = try await UsageHTTP.getJSON(url, headers: headers, session: session)
        return try rows(from: json)
    }

    /// Fixed diagnostic text only: never forward a provider body, token or URL error.
    static func issue(for error: Error) -> String {
        if let provider = error as? ProviderError {
            switch provider {
            case .notConfigured, .needsAuth: return "Cloud tasks unavailable. Sign in to Codex and retry."
            case .accessDenied: return "Cloud task credentials could not be accessed."
            case .unsupported: return "This account does not expose a supported cloud task endpoint."
            case .badResponse: return "Cloud task response could not be understood. Previous observations are retained."
            case .transport: return "Cloud task connection failed. Previous observations are retained."
            }
        }
        if error is ParseError { return "Cloud task inventory is incomplete or unsupported. Previous observations are retained." }
        return "Cloud task observation failed. Previous observations are retained."
    }

    static func unavailableRows(_ previous: [AgentRow], issue: String) -> [AgentRow] {
        previous.map { row in
            var stale = row
            stale.state = .unobserved
            stale.note = issue
            return stale
        }
    }

    /// Pure decoding boundary used by both the network path and contract tests.
    /// A changed response shape is an error, never a truthful-looking zero.
    static func rows(from json: [String: Any]) throws -> [AgentRow] {
        guard let items = json["items"] as? [[String: Any]] else {
            throw ParseError.missingItems
        }
        guard items.count <= 2_000 else { throw ParseError.capacityExceeded }
        for key in ["cursor", "next_cursor"] {
            if let value = json[key], !(value is NSNull) {
                guard let cursor = value as? String, cursor.isEmpty else { throw ParseError.incompleteInventory }
            }
        }
        if let value = json["has_more"], !(value is NSNull) {
            guard let more = value as? NSNumber, CFGetTypeID(more) == CFBooleanGetTypeID(),
                  !more.boolValue else { throw ParseError.incompleteInventory }
        }
        var seen = Set<String>()
        return try items.map { item in
            // Bounded, like every other reader of vendor text here.
            //
            // `id` below is capped at 256 bytes and its control characters
            // refused; the strings that reach the *screen* were not capped at
            // all. Each of these is rendered in the menu bar's dropdown: the
            // status becomes the state pill's label, which sits in a 68pt
            // frame, and the title becomes the row name — which in full mode
            // carries `.fixedSize(horizontal: true)` and so cannot truncate,
            // whatever `.lineLimit(1)` says above it. A cloud task with a long
            // title therefore asked for a row wider than the panel.
            //
            // 64 is the providers' `maxText`, for the same reason and with
            // the same grapheme-safe truncation.
            func string(_ keys: [String]) -> String? {
                for k in keys where !((item[k] as? String) ?? "").isEmpty {
                    return String((item[k] as! String).prefix(maxText))
                }
                return nil
            }
            func date(_ keys: [String]) throws -> Date? {
                for key in keys {
                    guard let value = item[key], !(value is NSNull) else { continue }
                    let parsed: Date?
                    if let text = value as? String { parsed = UsageHTTP.parseDate(text) }
                    else { parsed = FieldPath.numeric(value).map(Date.init(timeIntervalSince1970:)) }
                    guard let parsed, parsed.timeIntervalSince1970.isFinite,
                          (0...253_402_300_799).contains(parsed.timeIntervalSince1970) else { throw ParseError.invalidDate }
                    return parsed
                }
                return nil
            }
            // The identifier is read unclamped: it is matched against, not
            // drawn, and silently truncating it would merge two tasks whose
            // ids share a prefix. Its own bound is below.
            func identifier(_ keys: [String]) -> String? {
                for k in keys { if let v = item[k] as? String, !v.isEmpty { return v } }
                return nil
            }
            guard let id = identifier(["id", "task_id", "uuid"]), id.utf8.count <= 256,
                  !id.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  !id.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw ParseError.malformedItem }
            guard seen.insert(id).inserted else { throw ParseError.duplicateIdentity }
            let title = string(["title", "name", "summary"]) ?? "Cloud task"
            var row = AgentRow(
                id: "codex-cloud-\(id)",
                agentID: "codex",
                name: title,
                cwd: "",
                state: .cloud(string(["status", "state"]) ?? "cloud"),
                startedAt: try date(["created_at", "started_at"]),
                lastActivity: try date(["updated_at", "completed_at", "created_at"]))
            row.isRemote = true
            row.model = string(["model"])
            // Cloud tasks have no working directory, so the repo goes in the
            // tooltip field rather than the (now removed) project field.
            row.sessionName = string(["repo", "repository", "environment_label",
                                      "environment"]) ?? "cloud"
            return row
        }
    }
}
