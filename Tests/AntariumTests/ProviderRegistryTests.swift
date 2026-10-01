import Foundation
import Testing
@testable import Antarium

private final class Stub: UsageProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let isConfigured = true
    let setupHint = "stub"
    let isVerified = false
    init(_ id: String) { self.id = id; self.displayName = id }
    func fetch() async throws -> Snapshot { throw ProviderError.unsupported("stub") }
}

/// Which providers exist, and which one a descriptor is allowed to be.
@Suite("Provider registry", .serialized)
struct ProviderRegistryTests {

    private func descriptor(_ id: String, endpoint: String = "https://example.invalid/u") throws
        -> HarnessDescriptor {
        try HarnessDocument.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "id": id, "name": id, "process": [:],
            "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": endpoint,
                      "credential": ["kind": "env", "name": "STUB_TOKEN"],
                      "windows": ["root": "usage", "usedPercent": "percent"]],
        ])).descriptor
    }

    @Test("A descriptor cannot displace a provider written in Swift")
    func descriptorsNeverReplaceNativeProviders() throws {
        // The native providers carry auth that is control flow — Keychain
        // access and OAuth refresh — and has been checked against the real
        // service. A file in ~/.antarium/harnesses claiming their id must not
        // silently become the thing the menu bar asks for usage.
        let native = ["claude-code", "codex", "cursor"]
        let impostors = try native.map { try descriptor($0) }
        #expect(ProviderRegistry.providers(from: impostors).isEmpty,
                "a descriptor took over a native provider's id")

        // An id Swift does not cover is exactly the case descriptors are for.
        let contributed = ProviderRegistry.providers(from: [try descriptor("brand-new-agent")])
        #expect(contributed.map(\.id) == ["brand-new-agent"])
    }

    @Test("A provider keeps its identity while its descriptor is unchanged")
    func providerIdentityIsStableAcrossReads() throws {
        // The provider holds a URLSession and whatever state a fetch left
        // behind. Rebuilding it on every read of the registry would throw
        // that away several times a scan.
        let same = try descriptor("stable-agent")
        let first = ProviderRegistry.providers(from: [same]).first
        let second = ProviderRegistry.providers(from: [same]).first
        #expect(first != nil)
        #expect(first === second, "the provider was rebuilt for an unchanged descriptor")

        // A changed descriptor is a different provider: the old one is
        // configured for an endpoint that is no longer declared.
        let edited = try descriptor("stable-agent", endpoint: "https://example.invalid/v2")
        let third = ProviderRegistry.providers(from: [edited]).first
        #expect(third !== first, "an edited descriptor kept its old provider")
    }

    @Test("The menu bar is never left with nothing in it")
    func enabledFallsBackRatherThanEmptying() {
        // `enabled` filters the registry by the user's choice. A choice that
        // names only agents which no longer exist would otherwise leave no
        // items at all — and the menu bar is the only way back into the app.
        let all: [UsageProvider] = [Stub("a"), Stub("b")]
        #expect(ProviderRegistry.shown(from: all, enabled: ["b"]).map(\.id) == ["b"])
        #expect(ProviderRegistry.shown(from: all, enabled: ["gone"]).map(\.id) == ["a"])
        #expect(ProviderRegistry.shown(from: all, enabled: []).map(\.id) == ["a"])
        // And an empty registry yields nothing rather than trapping on all[0].
        #expect(ProviderRegistry.shown(from: [], enabled: ["a"]).isEmpty)
    }
}

/// What the dashboard shows while a refresh is failing.
@Suite("Quota store")
@MainActor
struct QuotaStoreTests {

    @Test("A failed refresh keeps the last reading, marked as failed")
    func failureRetainsTheLastSnapshot() {
        let store = QuotaStore()
        let snapshot = Snapshot(providerID: "p",
                                gauges: [Gauge(id: "w", badge: "5H", title: "W", used: 0.4,
                                               resetsAt: nil, reportedSeverity: .normal)],
                                extras: [], accountLabel: "pro", fetchedAt: Date())
        // Deliberately not stored first. Storing it and then failing leaves
        // the value in place regardless, so it cannot tell whether the failure
        // path restores it — which is the thing being checked. The caller
        // holds the last good reading and hands it back with the error.
        store.set(providerID: "p", error: .transport("offline"), last: snapshot)
        #expect(store.snapshot(for: "p") == snapshot,
                "a failed refresh discarded the reading it was given")
        #expect(store.primaryGauge(for: "p")?.id == "w")

        // A second failure with the same history keeps it.
        store.set(providerID: "p", error: .transport("still offline"), last: snapshot)
        #expect(store.snapshot(for: "p") == snapshot)

        // A provider removed from the bar leaves nothing behind.
        store.remove(providerID: "p")
        #expect(store.snapshot(for: "p") == nil)
    }

    @Test("A first fetch that fails shows no figure rather than an invented one")
    func failureWithNoHistoryShowsNothing() {
        let store = QuotaStore()
        store.set(providerID: "p", error: .needsAuth("sign in"), last: nil)
        #expect(store.snapshot(for: "p") == nil)
        #expect(store.primaryGauge(for: "p") == nil)
    }
}
