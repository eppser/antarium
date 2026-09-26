import Foundation
import Testing
@testable import Antarium

/// Gemini reports headroom as a fraction of one. Everything here exists
/// because reading 0.87 as a percentage gives 99.13% used — a number that is
/// wrong, alarming, and entirely plausible on a gauge.
@Suite("Gemini quota mapping", .serialized)
struct GeminiSnapshotTests {

    private func snapshot(_ buckets: [[String: Any]]) throws -> Snapshot {
        try GeminiProvider.makeSnapshot(["buckets": buckets])
    }

    @Test("Headroom is a fraction of one, not a percentage")
    func fractionIsNotPercent() throws {
        let found = try snapshot([
            ["modelId": "synthetic-pro", "tokenType": "input", "remainingFraction": 0.75]])
        let gauge = try #require(found.gauges.first)
        #expect(gauge.used == 0.25, "0.75 left is a quarter used, not three quarters")
    }

    @Test("A full bucket is empty of usage and a spent one is full")
    func extremes() throws {
        let full = try snapshot([["modelId": "m", "tokenType": "input", "remainingFraction": 1]])
        #expect(full.gauges.first?.used == 0)
        let spent = try snapshot([["modelId": "m", "tokenType": "input", "remainingFraction": 0]])
        #expect(spent.gauges.first?.used == 1)
    }

    @Test("Each bucket is named for its model, so two are told apart")
    func bucketsAreDistinct() throws {
        let found = try snapshot([
            ["modelId": "synthetic-pro", "tokenType": "input", "remainingFraction": 0.5],
            ["modelId": "synthetic-flash", "tokenType": "input", "remainingFraction": 0.5]])
        #expect(found.gauges.map(\.id) == ["synthetic-pro-input", "synthetic-flash-input"])
        #expect(Set(found.gauges.map(\.title)).count == 2, "both rows read the same")
    }

    @Test("A reset time is read when the service gives one")
    func resetTime() throws {
        let found = try snapshot([["modelId": "m", "tokenType": "input",
                                   "remainingFraction": 0.5,
                                   "resetTime": "2026-10-01T00:00:00Z"]])
        #expect(found.gauges.first?.resetsAt == Date(timeIntervalSince1970: 1_790_812_800))
    }

    @Test("A bucket with no readable fraction is left out, not charted at zero")
    func unreadableBucketsAreDropped() throws {
        let found = try snapshot([
            ["modelId": "good", "tokenType": "input", "remainingFraction": 0.5],
            ["modelId": "bad", "tokenType": "input"],
            ["modelId": "worse", "tokenType": "input", "remainingFraction": "not a number"]])
        #expect(found.gauges.map(\.id) == ["good-input"])
    }

    /// A bucket the service sends with no model and no token type has nothing
    /// to call itself. Charting it gives a row with a blank name and a blank
    /// badge, which reads as a rendering fault rather than as missing data.
    @Test("A bucket with nothing to name it is left out")
    func unnamedBucketsAreDropped() throws {
        let found = try snapshot([
            ["remainingFraction": 0.5],
            ["modelId": "good", "tokenType": "input", "remainingFraction": 0.5]])
        #expect(found.gauges.map(\.id) == ["good-input"])
    }

    @Test("A bucket named by only one of the two fields still counts")
    func partiallyNamedBucketsSurvive() throws {
        let byModel = try snapshot([["modelId": "m", "remainingFraction": 0.5]])
        #expect(byModel.gauges.map(\.id) == ["m"])
        let byType = try snapshot([["tokenType": "input", "remainingFraction": 0.5]])
        #expect(byType.gauges.map(\.id) == ["input"])
    }

    @Test("A reply with nothing readable in it is an error, not an empty gauge set", arguments: [
        [[String: Any]](),
        [["modelId": "m", "tokenType": "input"]],
    ])
    func emptyRepliesThrow(_ buckets: [[String: Any]]) {
        #expect(throws: ProviderError.self) { _ = try snapshot(buckets) }
    }

    @Test("A reply that is not buckets at all is an error")
    func wrongShapeThrows() {
        #expect(throws: ProviderError.self) {
            _ = try GeminiProvider.makeSnapshot(["somethingElse": 1])
        }
    }

    @Test("A flood of buckets is bounded, and the text in them clamped")
    func boundedWork() throws {
        let long = String(repeating: "M", count: 10_000)
        let many = (0..<500).map {
            ["modelId": "\(long)-\($0)", "tokenType": "input", "remainingFraction": 0.5]
                as [String: Any]
        }
        let found = try snapshot(many)
        #expect(found.gauges.count <= GeminiProvider.maxBuckets)
        let clamped = found.gauges.allSatisfy { $0.title.count <= GeminiProvider.maxText }
        #expect(clamped)
    }
}

/// The reason this provider is native: the token expires and renewing it
/// means writing the result back.
@Suite("Gemini credential handling", .serialized)
struct GeminiCredentialTests {

    private func withHome<T>(_ contents: String?, _ body: (GeminiProvider) -> T) -> T {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let contents {
            try? Data(contents.utf8).write(to: home.appendingPathComponent("oauth_creds.json"))
        }
        let previous = ProcessInfo.processInfo.environment["GEMINI_HOME"]
        setenv("GEMINI_HOME", home.path, 1)
        defer {
            if let previous { setenv("GEMINI_HOME", previous, 1) } else { unsetenv("GEMINI_HOME") }
            try? FileManager.default.removeItem(at: home)
        }
        ConfiguredProbe.invalidate()
        return body(GeminiProvider())
    }

    @Test("A stored token is a sign-in")
    func storedToken() {
        withHome(#"{"access_token":"synthetic","refresh_token":"r","expiry_date":1790000000000}"#) {
            #expect($0.isConfigured)
            #expect($0.credentials()?.accessToken == "synthetic")
            #expect($0.credentials()?.canRefresh == true)
        }
    }

    @Test("A file with no usable token is not a sign-in", arguments: [
        "{}", #"{"access_token":""}"#, "not json",
    ])
    func unusableFiles(_ contents: String) {
        withHome(contents) { #expect($0.isConfigured == false) }
    }

    @Test("No file at all is not a sign-in")
    func noFile() {
        withHome(nil) { #expect($0.isConfigured == false) }
    }

    /// The margin matters: a token expiring while the request is in flight
    /// comes back as a 401, which reads as "signed out" to whoever sees it.
    @Test("A token near its expiry is stale before it expires")
    func staleness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func creds(_ offset: TimeInterval) -> GeminiProvider.Credentials {
            .init(accessToken: "t", expiresAt: now.addingTimeInterval(offset), canRefresh: true)
        }
        #expect(creds(3600).isStale(at: now) == false)
        #expect(creds(30).isStale(at: now), "expiring inside the margin")
        #expect(creds(-1).isStale(at: now))
        // A credential with no stated expiry is used rather than pre-emptively
        // refreshed; the 401 path handles it if it turns out to be dead.
        #expect(GeminiProvider.Credentials(accessToken: "t", expiresAt: nil, canRefresh: true)
            .isStale(at: now) == false)
    }

    @Test("A credentials file too large to be a credential is refused")
    func oversized() {
        let padding = String(repeating: "x", count: 512 * 1_024)
        withHome(#"{"access_token":"\#(padding)"}"#) {
            #expect($0.credentials() == nil)
        }
    }
}
