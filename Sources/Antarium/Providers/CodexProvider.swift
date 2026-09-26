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
///
/// Cross-read 2026-09-25 against ClaudeBar's Codex probe. Same endpoint, same
/// `rate_limit.primary_window` / `.secondary_window` with `used_percent`, and
/// this reads more of the reply than that one does: the code-review limit and
/// the wrapped entries in `additional_rate_limits` have no counterpart there.
///
/// One difference is recorded and not acted on. That probe reads
/// `x-codex-primary-used-percent` and `x-codex-secondary-used-percent` from
/// the response headers first and treats the body as the fallback, where this
/// reads only the body. Whether the headers ever carry a figure the body
/// omits is unknown — if they do not, the two are the same reading by a
/// different route. Plumbing headers out of `UsageHTTP` to find out would be
/// building on a guess about somebody else's API, and the figure here came
/// from a live account rather than from inference.
///
/// Re-read 2026-09-26 against that tool's commits since, and one is evidence
/// worth acting on. It fixed its Codex countdown by carrying `resetsAt` — epoch
/// seconds — and `windowDurationMins` out of Codex's *app-server RPC*, a
/// different transport from this HTTP endpoint and camelCase where this reply is
/// snake_case. The verified fields here are `used_percent` and
/// `limit_window_seconds`, and no reset was among them, so a Codex gauge shows a
/// window length and no countdown where Claude's shows both.
///
/// Both names are now candidates. Adding one cannot produce a wrong figure: a
/// field that is not in the reply changes nothing, and a field that is turns a
/// missing countdown into a real one. `windowDurationMins` is converted from
/// minutes rather than joined to the seconds list, because a length in the wrong
/// unit *is* a wrong figure — sixty times too long would name a five-hour window
/// "12D". What is still not established is whether this endpoint carries either,
/// and reading it to find out would mean reading somebody's account.
final class CodexProvider: UsageProvider, @unchecked Sendable {
    let id = "codex"
    let displayName = "ChatGPT (Codex)"
    var setupHint: String {
        "Run `/Applications/ChatGPT.app/Contents/Resources/codex login` in Terminal."
    }
    let isVerified = true
    let signInCommand: String? = "codex login"

    let relocationVariable: String? = "CODEX_HOME"

    /// `CODEX_HOME` relocates the whole config directory; honour it.
    ///
    /// Read through `relocationVariable` rather than from a literal, so the
    /// name the harness is held against is the name actually used.
    fileprivate var codexHome: URL {
        if let home = ProcessInfo.processInfo.environment[relocationVariable ?? ""],
           !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Logged because "signed in" and "the API accepts it" are different
    /// things, and only the second one puts numbers on screen.
    var isConfigured: Bool {
        ConfiguredProbe.value(id) { self.credentials() != nil }
    }

    /// Everything the Codex API needs, read once from one place.
    ///
    /// There were three answers to "is Codex signed in" in this file.
    /// `isConfigured` asked whether auth.json existed, `fetch` extracted a
    /// token four ways, and `storedAuth` extracted it three — omitting
    /// `OPENAI_API_KEY`. A user whose auth.json holds only that key got a
    /// working quota gauge and cloud tasks reporting "credentials
    /// unavailable": two parts of the app disagreeing, each correct by its
    /// own rule. `ClaudeCredentials` is the shape this should have had.
    ///
    /// Bounded, because another application writes this file and everything
    /// else here reads through `BoundedFile`.
    fileprivate func credentials() -> (token: String, accountID: String?)? {
        let file = codexHome.appendingPathComponent("auth.json")
        let auth = (try? BoundedFile.read(file, maxBytes: 256 * 1_024))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
        // auth.json nests the ChatGPT login under `tokens`; an API-key login
        // sits at the top level.
        let tokens = auth?["tokens"] as? [String: Any]
                  ?? auth?["chatgpt_auth_tokens"] as? [String: Any]
        let token = tokens?["access_token"] as? String
                 ?? auth?["access_token"] as? String
                 ?? auth?["OPENAI_API_KEY"] as? String
                 ?? envToken
        guard let token, !token.isEmpty else { return nil }
        return (token, tokens?["account_id"] as? String ?? auth?["account_id"] as? String)
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
        CodexProvider().credentials()
    }

    func fetch() async throws -> Snapshot {
        guard let found = credentials() else {
            // "No file at all" and "a file with no token in it" are different
            // situations and want different advice.
            throw FileManager.default.fileExists(
                atPath: codexHome.appendingPathComponent("auth.json").path)
                ? ProviderError.needsAuth("Codex's auth.json has no access token.")
                : ProviderError.notConfigured("Codex isn't signed in on this Mac.")
        }

        var headers = ["Authorization": "Bearer \(found.token)"]
        if let accountID = found.accountID {
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
            // Straight out of the response and into a menu item. Clamped
            // here for the same reason the descriptor providers clamp theirs:
            // the 2 MiB body cap is the only other bound on it.
            let label = (extra["limit_name"] as? String).map(clamped)
                ?? (extra["metered_feature"] as? String).map(clamped) ?? "Extra \(i + 1)"
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

        let plan = (json["plan_type"] as? String).map { "\(clamped($0)) plan" }
        Log.info("codex", "Usage response parsed: \(gauges.count) primary windows, \(extras.count) additional windows.")
        return Snapshot(providerID: "codex", gauges: gauges, extras: extras,
                        accountLabel: plan, fetchedAt: Date())
    }

    private static func parseWindow(_ d: [String: Any], id: String,
                                    nameOverride: String? = nil) -> Gauge? {
        func number(_ keys: [String]) -> Double? {
            for k in keys {
                // A boolean is an `NSNumber` and bridges to `Int` as 0 or 1, so
                // `"used_percent": true` read as one per cent used and
                // `"resetsAt": true` as a reset one second after 1970. `FieldPath`
                // has always refused booleans as figures — this local helper
                // never got the guard, and every numeric field of this reply went
                // through it.
                if let n = d[k] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { continue }
                if let v = d[k] as? Double { return v }
                if let v = d[k] as? Int { return Double(v) }
            }
            return nil
        }
        guard let used = number(["used_percent", "utilization", "percent_used", "percent"])
        else { return nil }

        // Every one of these is a JSON number off the network, and each is
        // divided and converted to an `Int` further on — in `windowName`
        // here, and in `Format` once the date reaches a row. `Int(1e30)`
        // traps, so an unbounded value took the menu bar down rather than
        // reporting a window it could not read. `FieldPath` bounds both
        // kinds: a date to the year 9999, a window to ten years.
        // `windowDurationMins` is *minutes*, and is converted here rather than
        // being added to the seconds list above — a length in the wrong unit is
        // a wrong figure, not a missing one, and sixty times too long would
        // name a five-hour window "12D".
        let span = FieldPath.seconds(number(["limit_window_seconds", "window_seconds"]))
            ?? FieldPath.seconds(number(["windowDurationMins"]).map { $0 * 60 })
        var resets: Date?
        if let at = number(["reset_at", "resets_at_epoch", "resetsAt"]) {
            resets = FieldPath.epoch(at)
        } else if let after = FieldPath.seconds(number(["reset_after_seconds",
                                                        "resets_in_seconds"])) {
            resets = Date().addingTimeInterval(after)
        } else if let iso = (d["resets_at"] as? String) ?? (d["resetsAt"] as? String) {
            resets = UsageHTTP.parseDate(iso)
        }

        return Gauge(id: id, badge: "", title: nameOverride ?? windowName(span),
                     used: used / 100, resetsAt: resets, reportedSeverity: .normal,
                     windowSeconds: span)
    }

    /// Response text that reaches a menu item, bounded the way every other
    /// provider bounds its own.
    static let maxText = 64
    private static func clamped(_ text: String) -> String {
        text.count <= maxText ? text : String(text.prefix(maxText))
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
