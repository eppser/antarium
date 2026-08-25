import Foundation

/// Codex cloud tasks — agents running on Anthropic's… no, on OpenAI's
/// infrastructure rather than this Mac.
///
/// `GET chatgpt.com/backend-api/wham/tasks` is authenticated with the same
/// credentials as the usage endpoint and returns `{ items: [...], cursor }`.
/// **The item shape is unverified**: the account had no cloud tasks running
/// when this was written, so the field names below are read defensively and a
/// task that can't be understood is skipped rather than guessed at.
enum CloudScan {
    enum ParseError: Error {
        case missingItems
    }

    private static let session = UsageHTTP.makeSession(headers: [
        "User-Agent": "Antarium/1.0 (macOS menu bar)",
        "Accept": "application/json",
    ])

    static func codexTasks() async throws -> [AgentRow] {
        guard let auth = CodexProvider.storedAuth() else { return [] }
        var headers = ["Authorization": "Bearer \(auth.token)"]
        if let account = auth.accountID { headers["ChatGPT-Account-Id"] = account }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/tasks")
        else { throw URLError(.badURL) }
        let json = try await UsageHTTP.getJSON(url, headers: headers, session: session)
        return try rows(from: json)
    }

    /// Pure decoding boundary used by both the network path and contract tests.
    /// A changed response shape is an error, never a truthful-looking zero.
    static func rows(from json: [String: Any]) throws -> [AgentRow] {
        guard let items = json["items"] as? [[String: Any]] else {
            throw ParseError.missingItems
        }
        return items.compactMap { item in
            func string(_ keys: [String]) -> String? {
                for k in keys { if let v = item[k] as? String, !v.isEmpty { return v } }
                return nil
            }
            func date(_ keys: [String]) -> Date? {
                for k in keys {
                    if let s = item[k] as? String, let d = UsageHTTP.parseDate(s) { return d }
                    if let n = item[k] as? Double { return Date(timeIntervalSince1970: n) }
                }
                return nil
            }
            guard let id = string(["id", "task_id", "uuid"]) else { return nil }
            let title = string(["title", "name", "summary", "prompt"]) ?? "Cloud task"
            var row = AgentRow(
                id: "codex-cloud-\(id)",
                agentID: "codex",
                name: title,
                cwd: "",
                state: .cloud(string(["status", "state"]) ?? "cloud"),
                startedAt: date(["created_at", "started_at"]),
                lastActivity: date(["updated_at", "completed_at", "created_at"]))
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
