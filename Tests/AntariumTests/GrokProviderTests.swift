import Foundation
import Testing
@testable import Antarium

/// Grok reports percentages *used*, and its credential file is keyed by
/// issuer and client rather than by anything a fixed path names.
@Suite("Grok billing mapping")
struct GrokSnapshotTests {

    @Test("The headline figure is credits used")
    func creditsUsed() throws {
        let found = try GrokProvider.makeSnapshot(
            ["config": ["creditUsagePercent": 96.0]])
        let gauge = try #require(found.gauges.first)
        #expect(gauge.used == 0.96, "96% used is nearly spent, not nearly full")
    }

    @Test("Per-product figures are reported alongside")
    func productsAreExtras() throws {
        let found = try GrokProvider.makeSnapshot(["config": [
            "creditUsagePercent": 10.0,
            "productUsage": [["product": "SyntheticBuild", "usagePercent": 84.0],
                             ["product": "SyntheticChat", "usagePercent": 12.0]]]])
        #expect(found.gauges.map(\.title) == ["Credits"])
        #expect(found.extras.map(\.title) == ["SyntheticBuild", "SyntheticChat"])
        #expect(found.extras.first?.used == 0.84)
    }

    /// With no overall figure the products are all there is, so they become
    /// the headline rather than being hidden in a dropdown behind nothing.
    @Test("With no overall figure the products are the headline")
    func productsPromoted() throws {
        let found = try GrokProvider.makeSnapshot(
            ["config": ["productUsage": [["product": "SyntheticBuild", "usagePercent": 5.0]]]])
        #expect(found.gauges.map(\.title) == ["SyntheticBuild"])
        #expect(found.extras.isEmpty)
    }

    @Test("The period end becomes the reset time")
    func periodEnd() throws {
        let found = try GrokProvider.makeSnapshot(["config": [
            "creditUsagePercent": 1.0,
            "currentPeriod": ["end": "2026-10-01T00:00:00Z"]]])
        #expect(found.gauges.first?.resetsAt == Date(timeIntervalSince1970: 1_790_812_800))
    }

    @Test("A reply with no readable figure is an error", arguments: [
        [:] as [String: Any],
        ["config": [:]],
        ["config": ["creditUsagePercent": "not a number"]],
        ["config": ["productUsage": [["product": "X"]]]],
    ])
    func unreadable(_ json: [String: Any]) {
        #expect(throws: ProviderError.self) { _ = try GrokProvider.makeSnapshot(json) }
    }

    @Test("Products are bounded and their names clamped")
    func bounded() throws {
        let long = String(repeating: "P", count: 5_000)
        let many = (0..<400).map {
            ["product": "\(long)-\($0)", "usagePercent": 5.0] as [String: Any]
        }
        let found = try GrokProvider.makeSnapshot(
            ["config": ["creditUsagePercent": 1.0, "productUsage": many]])
        #expect(found.extras.count <= GrokProvider.maxProducts)
        let clamped = found.extras.allSatisfy { $0.title.count <= GrokProvider.maxText }
        #expect(clamped)
    }
}

/// The credential file is the reason this provider is native.
@Suite("Grok credential selection", .serialized)
struct GrokCredentialTests {

    private func withHome<T>(_ contents: String?, _ body: (GrokProvider) -> T) -> T {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let contents {
            try? Data(contents.utf8).write(to: home.appendingPathComponent("auth.json"))
        }
        let previous = ProcessInfo.processInfo.environment["GROK_HOME"]
        setenv("GROK_HOME", home.path, 1)
        defer {
            if let previous { setenv("GROK_HOME", previous, 1) } else { unsetenv("GROK_HOME") }
            try? FileManager.default.removeItem(at: home)
        }
        ConfiguredProbe.invalidate()
        return body(GrokProvider())
    }

    private let entry = #"""
    {"https://auth.x.ai::synthetic-client":{"key":"synthetic-access","refresh_token":"synthetic-refresh","expires_at":"2027-01-01T00:00:00Z","oidc_issuer":"https://auth.x.ai","oidc_client_id":"synthetic-client"}}
    """#

    @Test("A credential under an issuer-and-client key is found")
    func keyedEntryIsFound() {
        withHome(entry) {
            #expect($0.isConfigured)
            let found = $0.credentials()
            #expect(found?.accessToken == "synthetic-access")
            #expect(found?.issuer == "https://auth.x.ai")
            #expect(found?.canRefresh == true)
        }
    }

    /// Several entries can be present. One that can be refreshed outlives one
    /// that cannot, so it is the one to use — not whichever the dictionary
    /// happened to yield first.
    @Test("A refreshable entry is preferred over one that cannot be refreshed")
    func refreshablePreferred() {
        let both = #"""
        {"aaa::one":{"key":"stale-access","oidc_issuer":"https://auth.x.ai","oidc_client_id":"one"},
         "zzz::two":{"key":"good-access","refresh_token":"r","oidc_issuer":"https://auth.x.ai","oidc_client_id":"two"}}
        """#
        withHome(both) { #expect($0.credentials()?.accessToken == "good-access") }
    }

    @Test("A file with no usable entry is not a sign-in", arguments: [
        "{}", #"{"k":{}}"#, #"{"k":{"key":""}}"#, "not json",
    ])
    func unusable(_ contents: String) {
        withHome(contents) { #expect($0.isConfigured == false) }
    }

    @Test("No file at all is not a sign-in")
    func noFile() {
        withHome(nil) { #expect($0.isConfigured == false) }
    }

    @Test("A credential too large to be a credential is refused")
    func oversized() {
        let padding = String(repeating: "x", count: 512 * 1_024)
        withHome(#"{"k":{"key":"\#(padding)"}}"#) { #expect($0.credentials() == nil) }
    }

    /// The token is refreshed before it dies, because a token that expires
    /// mid-request comes back as a 401 and reads as a sign-out.
    @Test("Staleness is judged with a margin")
    func staleness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func creds(_ offset: TimeInterval?) -> GrokProvider.Credentials {
            .init(accessToken: "t", refreshToken: "r",
                  expiresAt: offset.map { now.addingTimeInterval($0) },
                  issuer: "https://auth.x.ai", clientID: "c")
        }
        #expect(creds(3_600).isStale(at: now) == false)
        #expect(creds(60).isStale(at: now))
        #expect(creds(-1).isStale(at: now))
        #expect(creds(nil).isStale(at: now) == false)
    }

    /// An entry missing the issuer or client cannot be refreshed, and must
    /// say so rather than being handed to a refresh that posts nowhere.
    @Test("An entry without an issuer or client cannot be refreshed")
    func incompleteCannotRefresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!GrokProvider.Credentials(accessToken: "t", refreshToken: "r", expiresAt: now,
                                          issuer: nil, clientID: "c").canRefresh)
        #expect(!GrokProvider.Credentials(accessToken: "t", refreshToken: "r", expiresAt: now,
                                          issuer: "https://auth.x.ai", clientID: nil).canRefresh)
        #expect(!GrokProvider.Credentials(accessToken: "t", refreshToken: nil, expiresAt: now,
                                          issuer: "https://auth.x.ai", clientID: "c").canRefresh)
    }
}

/// Where a refresh token is allowed to be spent.
///
/// The issuer comes out of `~/.grok/auth.json`, which another application
/// writes, so it is input rather than configuration. Posting a bearer token
/// to the host a file names is the same mistake the zai credential made, and
/// it is worth a suite of its own because the guard is one line that nothing
/// else exercises.
@Suite("Grok refreshes only against x.ai")
struct GrokIssuerTests {

    @Test("The documented issuer resolves to its token endpoint")
    func accepted() throws {
        let url = try #require(GrokProvider.tokenEndpoint(issuer: "https://accounts.x.ai"))
        #expect(url.absoluteString == "https://accounts.x.ai/oauth2/token")
    }

    @Test("A trailing slash on the issuer does not double up the path")
    func trailingSlash() throws {
        let url = try #require(GrokProvider.tokenEndpoint(issuer: "https://accounts.x.ai/"))
        #expect(url.absoluteString == "https://accounts.x.ai/oauth2/token")
    }

    @Test("x.ai itself is accepted, not only its subdomains")
    func apexHost() {
        #expect(GrokProvider.tokenEndpoint(issuer: "https://x.ai") != nil)
    }

    /// The reason a suffix test is not enough. Each of these ends with the
    /// string `x.ai` and none of them is x.ai.
    @Test("A lookalike host is refused", arguments: [
        "https://evilx.ai", "https://notx.ai", "https://xx.ai",
        "https://attacker.com/x.ai",
    ])
    func lookalikeHost(_ issuer: String) {
        #expect(GrokProvider.tokenEndpoint(issuer: issuer) == nil,
                "a refresh token would be posted to \(issuer)")
    }

    @Test("A host that merely contains x.ai is refused")
    func containsButDoesNotEnd() {
        #expect(GrokProvider.tokenEndpoint(issuer: "https://x.ai.attacker.com") == nil)
    }

    /// A token sent without TLS is a token given away, whatever the host.
    @Test("A plaintext or non-web issuer is refused", arguments: [
        "http://accounts.x.ai", "ftp://accounts.x.ai", "file:///tmp/x.ai",
        "accounts.x.ai",
    ])
    func schemeRequired(_ issuer: String) {
        #expect(GrokProvider.tokenEndpoint(issuer: issuer) == nil)
    }

    @Test("A missing or empty issuer is refused rather than defaulted")
    func absentIssuer() {
        #expect(GrokProvider.tokenEndpoint(issuer: nil) == nil)
        #expect(GrokProvider.tokenEndpoint(issuer: "") == nil)
    }

    /// Hosts are case-insensitive, so the check has to be too — otherwise
    /// `https://ACCOUNTS.X.AI` is refused for a real account.
    @Test("The host comparison is case-insensitive")
    func caseInsensitive() {
        #expect(GrokProvider.tokenEndpoint(issuer: "https://ACCOUNTS.X.AI") != nil)
    }
}
