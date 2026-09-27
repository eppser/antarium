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

    /// Cross-read 2026-09-27 against the Claude probe of the tool this app is
    /// measured against, because `isVerified` was true here and nothing said what
    /// against — the standard every descriptor mapping is held to by
    /// `quota.documentation` and `quota.checkedAt`, and the seven providers
    /// written in Swift were outside it.
    ///
    /// Same endpoint, `https://api.anthropic.com/api/oauth/usage`. Same two
    /// shapes: a generic `limits` array carrying `kind`, `percent`, `resets_at`
    /// and `scope.model.display_name`, and the older flat windows `five_hour`,
    /// `seven_day`, `seven_day_sonnet`, `seven_day_opus` carrying `utilization`
    /// and `resets_at`. This reads `weekly_all` and `weekly_scoped` where that
    /// one reads `weekly_scoped`, and it chooses the binding week for the bar
    /// and lists the rest, which that one does not do.
    ///
    /// Two fields it reads and this does not, recorded rather than left to be
    /// rediscovered. `spend` carries `used`, `limit` and `enabled` as money, and
    /// `extra_usage` carries purchased credit. Both are amounts rather than
    /// meters, and this provider draws meters — a balance beside two windows is a
    /// different row, not a third gauge, and inventing a currency for it is how
    /// `moonshot` nearly reported a CNY balance in dollars. Neither is a defect;
    /// both are unbuilt.
    ///
    /// The transport was probed 2026-09-27: the endpoint answers 401 to an
    /// invalid credential, so the path is alive and `UsageHTTP` turns that into a
    /// sign-in prompt. The figures come from a live signed-in account.
    ///
    // MARK: - Parsing

    /// The API reports the same numbers two ways: a rich `limits` array and a
    /// set of flat top-level windows. We prefer `limits` (it carries severity
    /// and per-model scope) and fall back to the flat form.
    static func makeSnapshot(_ json: [String: Any], token: ClaudeToken) throws -> Snapshot {
        let parsed = (json["limits"] as? [[String: Any]] ?? []).compactMap(ParsedLimit.init)

        let sessionLimit = parsed.first { $0.group == "session" }
            ?? ParsedLimit(window: json["five_hour"], group: "session", title: "Session")
        // The flat fallback carries the per-model weeks too, and they were being
        // dropped. Cross-read 2026-09-27 against the tool this app is measured
        // against: it reads `seven_day_sonnet` and `seven_day_opus`, and its own
        // comment says model-scoped limits are reported in the newer `limits`
        // array as `weekly_scoped` *instead of* those dedicated fields. So they
        // are the older shape, and an account still served it showed a session
        // and one week here while the per-model weeks it also reported went
        // unread — including, on a plan where a model cap binds first, the week
        // that would actually stop the user.
        //
        // Named from the field rather than from a lookup table: the API may add
        // `seven_day_<model>` for a model this app has never heard of, and
        // "Weekly · sonnet" read from the key is better than silence.
        let flatWeeklies = [("seven_day", "Weekly")]
            + Self.flatModelWeekKeys(json).map { ($0, Self.flatWeekTitle($0)) }
        let weeklies = parsed.filter { $0.group == "weekly" }.nilIfEmpty
            ?? flatWeeklies.compactMap {
                ParsedLimit(window: json[$0.0], group: "weekly", title: $0.1)
            }.nilIfEmpty
            ?? []

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

    /// Top-level keys of the older shape's per-model weeks, in the order the
    /// reply lists them so two runs agree.
    ///
    /// Read from the reply rather than from a list of model names here: a plan
    /// with a model this app has never heard of still reports
    /// `seven_day_<model>`, and a week named from its own key is better than a
    /// week that is not shown.
    static func flatModelWeekKeys(_ json: [String: Any]) -> [String] {
        json.keys
            .filter { $0.hasPrefix("seven_day_") && $0 != "seven_day" }
            .sorted()
    }

    /// "seven_day_sonnet" reads as "Weekly · Sonnet". The suffix is the model as
    /// the API spells it, capitalised no further than its first letter — this is
    /// not the place to decide how somebody's model name is written.
    static func flatWeekTitle(_ key: String) -> String {
        let model = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ")
        guard let first = model.first else { return "Weekly" }
        return "Weekly · " + first.uppercased() + model.dropFirst()
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

        /// The group an entry belongs to when it does not name one.
        ///
        /// `group` and `kind` say the same thing at different resolutions,
        /// which this class already assumed by falling back from one to the
        /// other. The fallback only ran in that direction, so an entry
        /// carrying `kind` and no `group` was refused outright — and every
        /// entry being refused is not an error here, it is an empty `limits`
        /// array and a quiet drop to the flat windows below, which carry no
        /// severity and no per-model scope at all. A reply that had more to
        /// say would have been read as one that had less.
        static func group(forKind kind: String?) -> String? {
            switch kind {
            case "session": return "session"
            case "weekly_all", "weekly_scoped": return "weekly"
            default: return nil
            }
        }

        /// From a `limits[]` entry.
        convenience init?(_ dict: [String: Any]) {
            let named = dict["kind"] as? String
            guard let group = dict["group"] as? String ?? ParsedLimit.group(forKind: named),
                  !FieldPath.isBoolean(dict["percent"]),
                  let percent = dict["percent"] as? Double ?? (dict["percent"] as? Int).map(Double.init)
            else { return nil }
            let kind = named ?? group
            self.init(group: group,
                      title: ParsedLimit.title(kind: kind, scope: dict["scope"] as? [String: Any]),
                      percent: percent,
                      resetsAt: UsageHTTP.parseDate(dict["resets_at"]),
                      severity: ParsedLimit.severity(dict["severity"] as? String))
        }

        /// From a flat window object like `five_hour`.
        convenience init?(window: Any?, group: String, title: String) {
            guard let d = window as? [String: Any],
                  !FieldPath.isBoolean(d["utilization"]),
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
