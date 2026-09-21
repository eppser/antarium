import Foundation

/// Grok Build (xAI) credits, from the CLI's billing endpoint.
///
/// Native for two reasons a descriptor cannot cover. `~/.grok/auth.json` is
/// keyed by `<issuer>::<client-id>`, so no fixed field path names the entry —
/// it has to be found by looking at what is there. And the access token lasts
/// about an hour with no CLI that reissues it, so the refresh is done here,
/// against the issuer the credential itself names.
///
/// The refreshed token is held in memory and never written back. Rewriting
/// another application's credential file to save a network round trip is a
/// poor trade: the format is theirs to change, and a concurrent write from
/// the CLI would be a race over the user's login.
final class GrokProvider: UsageProvider, @unchecked Sendable {
    let id = "grok"
    let displayName = "Grok Build"
    var setupHint: String { "Run `grok` in Terminal and sign in." }
    let signInCommand: String? = "grok"
    let isVerified = false

    private let session = UsageHTTP.makeSession(headers: [
        "User-Agent": "Antarium/1.0 (macOS menu bar)",
        "Accept": "application/json",
    ])

    var home: URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }
    var credentialsFile: URL { home.appendingPathComponent("auth.json") }

    struct Credentials: Equatable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let issuer: String?
        let clientID: String?

        /// Refreshed early: a token that dies mid-request returns a 401, and a
        /// 401 reads as "signed out" to whoever sees the row.
        func isStale(at now: Date, margin: TimeInterval = 300) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= margin
        }
        var canRefresh: Bool {
            refreshToken != nil && issuer != nil && clientID != nil
        }
    }

    /// The best entry in the file.
    ///
    /// There may be several — one per issuer and client — and they are not
    /// equally useful: one that can be refreshed outlives one that cannot, so
    /// that is the tiebreak rather than whichever the dictionary happened to
    /// yield first. Bounded, because another application writes this file.
    func credentials(_ file: URL? = nil) -> Credentials? {
        guard let data = try? BoundedFile.read(file ?? credentialsFile, maxBytes: 256 * 1_024),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var found: [Credentials] = []
        for key in json.keys.sorted() {
            guard let entry = json[key] as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty else { continue }
            let refresh = (entry["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            found.append(Credentials(
                accessToken: token,
                refreshToken: refresh,
                expiresAt: (entry["expires_at"] as? String).flatMap(UsageHTTP.fastUTC),
                issuer: entry["oidc_issuer"] as? String,
                clientID: entry["oidc_client_id"] as? String))
        }
        return found.first { $0.canRefresh } ?? found.first
    }

    var isConfigured: Bool {
        ConfiguredProbe.value(id) { self.credentials() != nil }
    }

    /// Refreshed tokens live here for as long as they are good for. Reached
    /// through synchronous accessors: taking a lock directly in an async
    /// function is an error under Swift 6, and this type is read from more
    /// than one task.
    private let cacheLock = NSLock()
    private var refreshed: Credentials?

    private func heldCredentials() -> Credentials? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return refreshed
    }
    private func hold(_ credentials: Credentials) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        refreshed = credentials
    }

    func fetch() async throws -> Snapshot {
        guard var found = credentials() else {
            throw ProviderError.notConfigured("Grok isn't signed in on this Mac.")
        }
        if let held = heldCredentials(), !held.isStale(at: Date()) { found = held }

        if found.isStale(at: Date()), found.canRefresh, let fresh = try? await refresh(found) {
            found = fresh
        }
        do {
            return try await request(found.accessToken)
        } catch ProviderError.needsAuth(let message) {
            guard found.canRefresh, let fresh = try? await refresh(found),
                  fresh.accessToken != found.accessToken else {
                throw ProviderError.needsAuth(message)
            }
            return try await request(fresh.accessToken)
        }
    }

    private func request(_ token: String) async throws -> Snapshot {
        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        else { throw ProviderError.badResponse("Grok's endpoint is not a URL.") }
        return try Self.makeSnapshot(
            try await UsageHTTP.getJSON(url, headers: ["Authorization": "Bearer \(token)"],
                                        session: session))
    }

    /// Spends the refresh token at the issuer the credential names. The issuer
    /// is checked rather than trusted: it comes out of a file, and a bearer
    /// token must not be posted to whatever host that file says.
    private func refresh(_ credentials: Credentials) async throws -> Credentials {
        guard let issuer = credentials.issuer, let clientID = credentials.clientID,
              let token = credentials.refreshToken,
              let url = URL(string: issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            + "/oauth2/token"),
              url.scheme == "https", (url.host ?? "").hasSuffix("x.ai")
        else { throw ProviderError.needsAuth("Grok's stored login cannot be refreshed.") }

        let form = "grant_type=refresh_token"
            + "&refresh_token=" + encoded(token)
            + "&client_id=" + encoded(clientID)
        let json = try await UsageHTTP.postForm(
            url, body: form,
            headers: ["Content-Type": "application/x-www-form-urlencoded"], session: session)
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            throw ProviderError.needsAuth("Grok did not return a refreshed token.")
        }
        let lifetime = FieldPath.number(json, "expires_in").flatMap { $0.isFinite ? $0 : nil }
        let fresh = Credentials(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String) ?? credentials.refreshToken,
            expiresAt: lifetime.map { Date().addingTimeInterval($0) },
            issuer: credentials.issuer, clientID: credentials.clientID)
        hold(fresh)
        return fresh
    }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    static let maxProducts = 32
    static let maxText = 64

    /// Maps the billing reply onto gauges.
    ///
    ///     {"config": {"currentPeriod": {"end": "…"},
    ///                 "creditUsagePercent": 96,
    ///                 "productUsage": [{"product": "GrokBuild", "usagePercent": 84}]}}
    ///
    /// Both figures are percentages *used*.
    static func makeSnapshot(_ json: [String: Any]) throws -> Snapshot {
        let config = json["config"] as? [String: Any] ?? json
        let period = config["currentPeriod"] as? [String: Any]
        let resets = (period?["end"] as? String).flatMap(UsageHTTP.fastUTC)

        var gauges: [Gauge] = []
        if let used = FieldPath.number(config, "creditUsagePercent"), used.isFinite {
            gauges.append(Gauge(id: "credits", badge: "CR", title: "Credits",
                                used: min(max(used / 100, 0), 1), resetsAt: resets,
                                reportedSeverity: .normal))
        }
        var extras: [Gauge] = []
        for entry in (config["productUsage"] as? [[String: Any]] ?? []).prefix(maxProducts) {
            guard let name = (entry["product"] as? String).map(clamped), !name.isEmpty,
                  let used = FieldPath.number(entry, "usagePercent"), used.isFinite
            else { continue }
            extras.append(Gauge(id: name, badge: String(name.prefix(3)).uppercased(),
                                title: name, used: min(max(used / 100, 0), 1),
                                resetsAt: resets, reportedSeverity: .normal))
        }
        guard !gauges.isEmpty || !extras.isEmpty else {
            throw ProviderError.badResponse("Grok reported no readable credit figure.")
        }
        return Snapshot(providerID: "grok",
                        gauges: gauges.isEmpty ? extras : gauges,
                        extras: gauges.isEmpty ? [] : extras,
                        accountLabel: nil, fetchedAt: Date())
    }

    private static func clamped(_ text: String) -> String {
        text.count <= maxText ? text : String(text.prefix(maxText))
    }
}
