import Foundation

/// Reads Claude Code's own rate-limit windows from the endpoint the CLI's
/// `/usage` command uses, authenticated with the credentials already on disk.
///
/// Note on windows: Claude Code has no *daily* limit. The two that gate you are
/// a rolling 5-hour session window and a rolling 7-day week, so those are the
/// two rows we draw.
final class ClaudeCodeProvider: UsageProvider, @unchecked Sendable {
    let id = "claude-code"
    let displayName = "Claude Code"
    var setupHint: String { "Run `claude` in Terminal and sign in." }
    let signInCommand: String? = "claude auth login"
    /// Memoised: the fallback path runs `/usr/bin/security`, and this is
    /// read from a SwiftUI body.
    var isConfigured: Bool {
        ConfiguredProbe.value(id) { ClaudeCredentials.hasAnyCredentials }
    }
    let isVerified = true

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session = UsageHTTP.makeSession(headers: [
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "Antarium/1.0 (macOS menu bar)",
        "Accept": "application/json",
    ])

    func fetch() async throws -> Snapshot {
        let load = ClaudeCredentials.load()
        guard !load.tokens.isEmpty else {
            throw load.keychainDenied
                ? ProviderError.accessDenied("Antarium can't read Claude Code's Keychain item.")
                : ProviderError.notConfigured("Claude Code isn't signed in on this Mac.")
        }

        // Try freshest first; a 401 usually just means that copy is stale while
        // another store (keychain vs. file) still holds a live one.
        // A denial outranks any later 401: if the Keychain locked us out, the
        // live token is almost certainly in there and the stale on-disk
        // leftover 401ing tells the user nothing useful.
        let denialError: ProviderError? = load.keychainDenied
            ? .accessDenied("Antarium can't read Claude Code's Keychain item.")
            : nil
        var lastAuthError = ProviderError.needsAuth("Claude Code's session expired — sign in again.")
        for token in load.tokens {
            do {
                let payload = try await request(token: token)
                return try Self.makeSnapshot(payload, token: token)
            } catch let err as ProviderError {
                if case .needsAuth = err { lastAuthError = err; continue }
                throw err
            }
        }
        throw denialError ?? lastAuthError
    }

    /// Goes through `UsageHTTP.getJSON` like every other provider, and used
    /// not to.
    ///
    /// It built its own `URLRequest` and called `session.data(for:)`, which
    /// looks equivalent and is not. The session's bounded delegate collects a
    /// body into an entry `UsageHTTP` registers per task; `data(for:)`
    /// registers none, so `didReceive data:` returned at its first guard and
    /// the running-total cap enforced nothing. The declared-length half still
    /// worked, which left exactly the case it cannot cover — a chunked reply
    /// that declares no length — unbounded, on the one provider that talks to
    /// Anthropic's own API.
    ///
    /// A refused cross-host redirect was the same shape: the refusal still
    /// happened, but the reason was recorded into an entry nobody was reading,
    /// so the caller saw whatever a cancelled redirect happens to look like
    /// instead of being told a credential was nearly sent elsewhere.
    private func request(token: ClaudeToken) async throws -> [String: Any] {
        try await UsageHTTP.getJSON(
            endpoint, headers: ["Authorization": "Bearer \(token.accessToken)"],
            session: session)
    }

    // MARK: - Parsing

    /// The API reports the same numbers two ways: a rich `limits` array and a
    /// set of flat top-level windows. We prefer `limits` (it carries severity
    /// and per-model scope) and fall back to the flat form.
    static func makeSnapshot(_ json: [String: Any], token: ClaudeToken) throws -> Snapshot {
        let parsed = (json["limits"] as? [[String: Any]] ?? []).compactMap(ParsedLimit.init)

        let sessionLimit = parsed.first { $0.group == "session" }
            ?? ParsedLimit(window: json["five_hour"], group: "session", title: "Session")
        let weeklies = parsed.filter { $0.group == "weekly" }.nilIfEmpty
            ?? [ParsedLimit(window: json["seven_day"], group: "weekly", title: "Weekly")].compactMap { $0 }

        guard let sessionLimit else {
            throw ProviderError.badResponse("Usage response had no session window.")
        }
        // The week you actually hit first is the highest of the weekly caps, so
        // that's what the bar tracks; the rest are listed in the dropdown.
        guard let binding = weeklies.max(by: { $0.percent < $1.percent }) else {
            throw ProviderError.badResponse("Usage response had no weekly window.")
        }

        let session = Gauge(id: "session", badge: "5H", title: "Session (5 hours)",
                            used: sessionLimit.percent / 100, resetsAt: sessionLimit.resetsAt,
                            reportedSeverity: sessionLimit.severity)
        let week = Gauge(id: "weekly", badge: "7D", title: binding.title,
                         used: binding.percent / 100, resetsAt: binding.resetsAt,
                         reportedSeverity: binding.severity)
        let extras = weeklies
            .filter { $0 !== binding }
            .sorted { $0.percent > $1.percent }
            .map { Gauge(id: $0.title, badge: "··", title: $0.title,
                         used: $0.percent / 100, resetsAt: $0.resetsAt,
                         reportedSeverity: $0.severity) }

        return Snapshot(providerID: "claude-code", gauges: [session, week], extras: extras,
                        accountLabel: token.subscriptionType.map { "\($0) plan" },
                        fetchedAt: Date())
    }

    /// One entry of the `limits` array, or one flat top-level window.
    final class ParsedLimit {
        let group: String
        let title: String
        let percent: Double
        let resetsAt: Date?
        let severity: Severity

        init(group: String, title: String, percent: Double, resetsAt: Date?, severity: Severity) {
            self.group = group; self.title = title; self.percent = percent
            self.resetsAt = resetsAt; self.severity = severity
        }

        /// From a `limits[]` entry.
        convenience init?(_ dict: [String: Any]) {
            guard let group = dict["group"] as? String,
                  let percent = dict["percent"] as? Double ?? (dict["percent"] as? Int).map(Double.init)
            else { return nil }
            let kind = dict["kind"] as? String ?? group
            self.init(group: group,
                      title: ParsedLimit.title(kind: kind, scope: dict["scope"] as? [String: Any]),
                      percent: percent,
                      resetsAt: UsageHTTP.parseDate(dict["resets_at"]),
                      severity: ParsedLimit.severity(dict["severity"] as? String))
        }

        /// From a flat window object like `five_hour`.
        convenience init?(window: Any?, group: String, title: String) {
            guard let d = window as? [String: Any],
                  let util = d["utilization"] as? Double ?? (d["utilization"] as? Int).map(Double.init)
            else { return nil }
            self.init(group: group, title: title, percent: util,
                      resetsAt: UsageHTTP.parseDate(d["resets_at"]), severity: .normal)
        }

        private static func title(kind: String, scope: [String: Any]?) -> String {
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            switch kind {
            case "session":       return "Session (5 hours)"
            case "weekly_all":    return "Weekly (all models)"
            case "weekly_scoped": return model.map { "Weekly · \($0)" } ?? "Weekly (scoped)"
            default:
                let pretty = kind.replacingOccurrences(of: "_", with: " ").capitalized
                return model.map { "\(pretty) · \($0)" } ?? pretty
            }
        }

        private static func severity(_ raw: String?) -> Severity {
            switch raw {
            case "warning", "warn": return .low
            case "critical", "exceeded", "blocked": return .critical
            default: return .normal
            }
        }
    }

}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
