import Foundation

/// ChatGPT via the Codex CLI.
///
/// The endpoint and credential path are taken from the `codex` CLI that ships
/// inside ChatGPT.app, so they are the real ones rather than a guess.
///
/// Verified against a live signed-in account: `GET /backend-api/wham/usage`
/// returns `rate_limit.primary_window` / `.secondary_window`, each carrying
/// `used_percent` and `limit_window_seconds`. The window length is read rather
/// than assumed — on a Plus plan the only active window is the 7-day one, so
/// hardcoding "5 hours" for the primary window would have been wrong.
final class CodexProvider: UsageProvider, @unchecked Sendable {
    let id = "codex"
    let displayName = "ChatGPT (Codex)"
    var setupHint: String {
        "Run `/Applications/ChatGPT.app/Contents/Resources/codex login` in Terminal."
    }
    let isVerified = true
    let signInCommand: String? = "codex login"

    /// `CODEX_HOME` relocates the whole config directory; honour it.
    fileprivate var codexHome: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Logged because "signed in" and "the API accepts it" are different
    /// things, and only the second one puts numbers on screen.
    var isConfigured: Bool {
        FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path)
            || envToken != nil
    }

    /// The CLI accepts these in place of a stored login.
    fileprivate var envToken: String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY"] {
            if let v = env[key], !v.isEmpty { return v }
        }
        return nil
    }

    private let session = UsageHTTP.makeSession(headers: [
        "User-Agent": "Antarium/1.0 (macOS menu bar)",
        "Accept": "application/json",
    ])

    /// Shared with the cloud-task scanner.
    static func storedAuth() -> (token: String, accountID: String?)? {
        let provider = CodexProvider()
        let auth = (try? Data(contentsOf: provider.codexHome.appendingPathComponent("auth.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
        let tokens = auth?["tokens"] as? [String: Any]
                  ?? auth?["chatgpt_auth_tokens"] as? [String: Any]
        let token = tokens?["access_token"] as? String
                 ?? auth?["access_token"] as? String
                 ?? provider.envToken
        guard let token, !token.isEmpty else { return nil }
        return (token, tokens?["account_id"] as? String ?? auth?["account_id"] as? String)
    }

    func fetch() async throws -> Snapshot {
        let auth = (try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil

        // auth.json nests the ChatGPT login under `tokens`; an API-key login
        // sits at the top level.
        let tokens = auth?["tokens"] as? [String: Any]
                  ?? auth?["chatgpt_auth_tokens"] as? [String: Any]
        let stored = tokens?["access_token"] as? String
                  ?? auth?["access_token"] as? String
                  ?? auth?["OPENAI_API_KEY"] as? String

        guard let accessToken = stored ?? envToken, !accessToken.isEmpty else {
            throw auth == nil
                ? ProviderError.notConfigured("Codex isn't signed in on this Mac.")
                : ProviderError.needsAuth("Codex's auth.json has no access token.")
        }

        var headers = ["Authorization": "Bearer \(accessToken)"]
        if let accountID = tokens?["account_id"] as? String ?? auth?["account_id"] as? String {
            headers["ChatGPT-Account-Id"] = accountID
        }

        let json = try await UsageHTTP.getJSON(
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            headers: headers, session: session)
        return try Self.makeSnapshot(json)
    }

    /// Maps the reported windows onto gauges. Tolerant about field naming,
    /// but never invents a figure: a window it can't read is left out.
    static func makeSnapshot(_ json: [String: Any]) throws -> Snapshot {
        let limits = json["rate_limit"] as? [String: Any] ?? json

        var gauges: [Gauge] = []
        for key in ["primary_window", "secondary_window"] {
            guard let window = limits[key] as? [String: Any],
                  let gauge = parseWindow(window, id: key) else { continue }
            gauges.append(gauge)
        }
        // Extra caps (code review, and anything added later) go to the dropdown.
        var extras: [Gauge] = []
        if let review = limits["code_review_rate_limit"] as? [String: Any]
            ?? json["code_review_rate_limit"] as? [String: Any],
           let gauge = parseWindow(review, id: "code_review", nameOverride: "Code review") {
            extras.append(gauge)
        }
        // Each entry is a wrapper — `{limit_name, metered_feature, rate_limit:
        // {primary_window, secondary_window}}` — not a window. Handing the
        // wrapper to parseWindow looked for `used_percent` at its top level,
        // found nothing, and dropped every model-specific cap on the floor:
        // this account's only five-hour window lives in here.
        for (i, extra) in (json["additional_rate_limits"] as? [[String: Any]] ?? []).enumerated() {
            let label = (extra["limit_name"] as? String)
                ?? (extra["metered_feature"] as? String) ?? "Extra \(i + 1)"
            let inner = extra["rate_limit"] as? [String: Any] ?? extra
            for key in ["primary_window", "secondary_window"] {
                guard let window = inner[key] as? [String: Any],
                      let gauge = parseWindow(window, id: "additional-\(i)-\(key)",
                                              nameOverride: label)
                else { continue }
                extras.append(gauge)
            }
        }

        guard !gauges.isEmpty else {
            throw ProviderError.badResponse("Codex reported no active usage window.")
        }
        // Shortest window first, so the fast-moving one is the top row.
        gauges.sort { ($0.windowSeconds ?? .greatestFiniteMagnitude)
                    < ($1.windowSeconds ?? .greatestFiniteMagnitude) }

        let plan = (json["plan_type"] as? String).map { "\($0) plan" }
        Log.info("codex", "plan=\(plan ?? "—") gauges=\(gauges.map(\.title)) "
            + "extras=\(extras.map(\.title)) "
            + "used=\(gauges.map { String(format: "%.1f%%", $0.used * 100) })")
        return Snapshot(providerID: "codex", gauges: gauges, extras: extras,
                        accountLabel: plan, fetchedAt: Date())
    }

    private static func parseWindow(_ d: [String: Any], id: String,
                                    nameOverride: String? = nil) -> Gauge? {
        func number(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = d[k] as? Double { return v }
                if let v = d[k] as? Int { return Double(v) }
            }
            return nil
        }
        guard let used = number(["used_percent", "utilization", "percent_used", "percent"])
        else { return nil }

        let span = number(["limit_window_seconds", "window_seconds"])
        var resets: Date?
        if let at = number(["reset_at", "resets_at_epoch"]) {
            resets = Date(timeIntervalSince1970: at)
        } else if let after = number(["reset_after_seconds", "resets_in_seconds"]) {
            resets = Date().addingTimeInterval(after)
        } else if let iso = d["resets_at"] as? String {
            resets = UsageHTTP.parseDate(iso)
        }

        return Gauge(id: id, badge: "", title: nameOverride ?? windowName(span),
                     used: used / 100, resetsAt: resets, reportedSeverity: .normal,
                     windowSeconds: span)
    }

    /// Names the window from its own length rather than its position.
    private static func windowName(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Usage" }
        switch seconds {
        case 18_000:  return "Session (5 hours)"
        case 604_800: return "Weekly"
        case 86_400:  return "Daily"
        default:
            let hours = Int((seconds / 3600).rounded())
            return hours >= 48 ? "Rolling \(hours / 24) days" : "Rolling \(hours) hours"
        }
    }
}
