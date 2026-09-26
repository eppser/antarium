import Foundation

/// Gemini CLI usage, from Cloud Code's own quota endpoint.
///
/// Native rather than a descriptor, and the reason is the credential rather
/// than the response. `~/.gemini/oauth_creds.json` holds an access token good
/// for about an hour and a refresh token, and spending a refresh token means
/// writing the result back — control flow, not a field path. A descriptor
/// version of this was written and reverted: the mapping worked and the gauge
/// would have read "sign in" most of the time, which docs/ECOSYSTEM.md is
/// explicit about not shipping.
///
/// The refresh is done the way the CLI itself does it: run `gemini`, let it
/// notice the token is stale and rewrite the file, then read the file again.
/// That avoids holding Google client secrets in this app at all.
final class GeminiProvider: UsageProvider, @unchecked Sendable {
    let id = "gemini"
    let displayName = "Gemini CLI"
    var setupHint: String { "Run `gemini` in Terminal and sign in." }
    let signInCommand: String? = "gemini"
    /// The mapping follows Cloud Code's documented shape and is fixture-tested;
    /// no live account has confirmed the numbers, and the row says so.
    let isVerified = false

    private let session = UsageHTTP.makeSession(headers: [
        "User-Agent": "Antarium/1.0 (macOS menu bar)",
        "Accept": "application/json",
    ])

    /// `GEMINI_HOME` is honoured for the same reason `CODEX_HOME` is, and it
    /// is what lets the credential handling be tested without touching a real
    /// one.
    let relocationVariable: String? = "GEMINI_HOME"

    var home: URL {
        if let home = ProcessInfo.processInfo.environment[relocationVariable ?? ""],
           !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    }

    var credentialsFile: URL { home.appendingPathComponent("oauth_creds.json") }

    struct Credentials: Equatable {
        let accessToken: String
        let expiresAt: Date?
        let canRefresh: Bool

        /// Treated as stale slightly early: a token that expires while the
        /// request is in flight fails as a 401, and a 401 is indistinguishable
        /// from "signed out" to the person reading the row.
        func isStale(at now: Date, margin: TimeInterval = 60) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= margin
        }
    }

    /// Bounded, like every other credential read here — another application
    /// writes this file.
    func credentials(_ file: URL? = nil) -> Credentials? {
        let url = file ?? credentialsFile
        guard let data = try? BoundedFile.read(url, maxBytes: 256 * 1_024),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty
        else { return nil }
        // Milliseconds since the epoch, as the CLI writes it.
        let expiry = FieldPath.number(json, "expiry_date")
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        let refresh = json["refresh_token"] as? String
        return Credentials(accessToken: token, expiresAt: expiry,
                           canRefresh: !(refresh ?? "").isEmpty)
    }

    var isConfigured: Bool {
        // Cheap and synchronous as the protocol requires: reads one file and
        // never runs the CLI, which `fetch` does off the main thread.
        ConfiguredProbe.value(id) { self.credentials() != nil }
    }

    func fetch() async throws -> Snapshot {
        guard var found = credentials() else {
            throw ProviderError.notConfigured("Gemini isn't signed in on this Mac.")
        }
        if found.isStale(at: Date()), found.canRefresh, refreshViaCLI() {
            found = credentials() ?? found
        }
        do {
            return try await request(found.accessToken)
        } catch ProviderError.needsAuth(let message) {
            // One retry, and only when there is something to spend: a second
            // 401 is a real sign-out, not a stale copy.
            guard found.canRefresh, refreshViaCLI(), let fresh = credentials(),
                  fresh.accessToken != found.accessToken else {
                throw ProviderError.needsAuth(message)
            }
            return try await request(fresh.accessToken)
        }
    }

    private func request(_ token: String) async throws -> Snapshot {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")
        else { throw ProviderError.badResponse("Gemini's endpoint is not a URL.") }
        let json = try await UsageHTTP.postJSON(
            url, headers: ["Authorization": "Bearer \(token)",
                           "Content-Type": "application/json"],
            session: session)
        return try Self.makeSnapshot(json)
    }

    /// Runs the CLI briefly so it refreshes its own token and rewrites the
    /// file. Bounded like every other subprocess here; a CLI that has wedged
    /// must not take the menu bar with it.
    @discardableResult
    private func refreshViaCLI() -> Bool {
        guard let path = CommandPath.resolve("gemini") else { return false }
        let result = Shell.execute(path, [], timeout: 20, outputLimit: 64 * 1_024,
                                   input: "/quit\n")
        if result.exitCode != 0 {
            Log.info("gemini", "CLI token refresh did not succeed")
        }
        return result.exitCode == 0
    }

    /// Maps the reported buckets onto gauges. Static and pure, so the mapping
    /// is testable with nothing installed.
    ///
    /// `remainingFraction` is headroom as a fraction of one: 0.87 means 87%
    /// left. Read as a percentage it becomes 99.13% used, which is wrong and
    /// alarming rather than merely wrong.
    static func makeSnapshot(_ json: [String: Any]) throws -> Snapshot {
        guard let buckets = json["buckets"] as? [[String: Any]] else {
            throw ProviderError.badResponse("Gemini reported no quota buckets.")
        }
        var gauges: [Gauge] = []
        for bucket in buckets.prefix(maxBuckets) {
            guard let fraction = FieldPath.number(bucket, "remainingFraction"),
                  fraction.isFinite else { continue }
            let model = (bucket["modelId"] as? String).map(clamped)
            let kind = (bucket["tokenType"] as? String).map(clamped)
            let id = [model, kind].compactMap { $0 }.joined(separator: "-")
            guard !id.isEmpty else { continue }
            gauges.append(Gauge(
                id: id,
                badge: String((model ?? id).prefix(3)).uppercased(),
                title: model ?? id,
                used: min(max(1 - fraction, 0), 1),
                resetsAt: (bucket["resetTime"] as? String).flatMap(UsageHTTP.fastUTC),
                reportedSeverity: .normal))
        }
        guard !gauges.isEmpty else {
            throw ProviderError.badResponse("Gemini reported no readable quota bucket.")
        }
        return Snapshot(providerID: "gemini", gauges: gauges, extras: [],
                        accountLabel: nil, fetchedAt: Date())
    }

    /// Same reasoning as the descriptor providers: these strings arrive over
    /// the network and end up in a menu item.
    static let maxBuckets = 32
    static let maxText = 64
    private static func clamped(_ text: String) -> String {
        text.count <= maxText ? text : String(text.prefix(maxText))
    }
}
