import Foundation
import Testing
@testable import Antarium

// MARK: - Auto-detection policy

/// A stand-in provider, so the policy can be tested on a machine that has none
/// of these agents installed.
private final class StubProvider: UsageProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let isConfigured: Bool
    let setupHint = "stub"
    let isVerified = false
    init(_ id: String, configured: Bool) {
        self.id = id
        self.displayName = id
        self.isConfigured = configured
    }
    func fetch() async throws -> Snapshot { throw ProviderError.unsupported("stub") }
}

@Test("Detection enables every agent with evidence and nothing else")
func autoEnablePicksWhatIsPresent() {
    let evidence = [
        AgentAutoEnable.Evidence(id: "claude-code", signedIn: true, hasSessions: true),
        AgentAutoEnable.Evidence(id: "copilot", signedIn: true, hasSessions: false),
        AgentAutoEnable.Evidence(id: "zai", signedIn: false, hasSessions: true),
        AgentAutoEnable.Evidence(id: "cursor", signedIn: false, hasSessions: false),
    ]
    let chosen = AgentAutoEnable.resolve(evidence, fallback: ["claude-code"])
    #expect(chosen == ["claude-code", "copilot", "zai"])
    #expect(!chosen.contains("cursor"))
}

@Test("A signed-out agent with sessions still earns a slot")
func autoEnableCountsSessionsAlone() {
    let only = [AgentAutoEnable.Evidence(id: "codex", signedIn: false, hasSessions: true)]
    #expect(AgentAutoEnable.resolve(only, fallback: ["claude-code"]) == ["codex"])
}

@Test("A bare Mac still gets one item, so there is a way back into the app")
func autoEnableNeverEmpties() {
    let nothing = [
        AgentAutoEnable.Evidence(id: "claude-code", signedIn: false, hasSessions: false),
        AgentAutoEnable.Evidence(id: "codex", signedIn: false, hasSessions: false),
    ]
    #expect(AgentAutoEnable.resolve(nothing, fallback: ["claude-code", "codex"]) == ["claude-code"])
    #expect(AgentAutoEnable.resolve([], fallback: []).isEmpty)
}

@Test("Evidence is read per provider, not per harness")
func autoEnableEvidenceShape() {
    let providers: [UsageProvider] = [StubProvider("a", configured: true),
                                      StubProvider("b", configured: false)]
    let evidence = AgentAutoEnable.evidence(providers: providers, sessionsPresent: ["b", "z"])
    #expect(evidence == [
        AgentAutoEnable.Evidence(id: "a", signedIn: true, hasSessions: false),
        AgentAutoEnable.Evidence(id: "b", signedIn: false, hasSessions: true),
    ])
    // "z" has sessions but no provider, so it cannot become a menu bar item.
    #expect(!evidence.contains { $0.id == "z" })
}

// MARK: - isConfigured must stay cheap

@Test("A repeated isConfigured probe runs the expensive answer once")
func configuredProbeMemoises() {
    let key = "probe-test-\(UUID().uuidString)"
    var calls = 0
    let first = ConfiguredProbe.value(key, now: 1_000) { calls += 1; return true }
    let second = ConfiguredProbe.value(key, now: 1_005) { calls += 1; return false }
    #expect(first == true)
    #expect(second == true)
    #expect(calls == 1)

    // Past the window it asks again.
    let third = ConfiguredProbe.value(key, now: 1_000 + ConfiguredProbe.ttl + 1) {
        calls += 1; return false
    }
    #expect(third == false)
    #expect(calls == 2)

    ConfiguredProbe.invalidate(key)
    _ = ConfiguredProbe.value(key, now: 1_000 + ConfiguredProbe.ttl + 2) { calls += 1; return true }
    #expect(calls == 3)
}

// MARK: - Quota mappings, without an account or a network

@Test("Every shipped quota descriptor has a fixture and that fixture passes")
func bundledQuotaFixturesPass() {
    let descriptors = HarnessCLI.bundledDescriptors().filter { $0.quota != nil }
    #expect(!descriptors.isEmpty, "no descriptor declares a quota block")
    for descriptor in descriptors {
        let report = QuotaFixture.verify(descriptor, in: AppResources.bundle)
        #expect(report != nil)
        #expect(report?.passed == true, "\(descriptor.id): \(report?.detail ?? "no report")")
    }
}

/// The window shapes, exercised directly. `windows(in:map:)` is the part that
/// decides what a response even contains, so it is tested apart from the
/// percentage arithmetic layered on top.
@Test("A keyed object yields its windows in declared order")
func keyedWindowsKeepDeclaredOrder() {
    var map = HarnessDescriptor.Quota.Windows()
    map.root = "quota"
    map.keys = ["b", "a"]
    let found = DescriptorProvider.windows(
        in: ["quota": ["a": ["p": 1], "b": ["p": 2], "c": ["p": 3]]], map: map)
    #expect(found.map(\.key) == ["b", "a"])
}

@Test("A list is keyed by the fields named, joined when one is ambiguous")
func listWindowsUseCompositeKeys() {
    var map = HarnessDescriptor.Quota.Windows()
    map.list = "data.limits"
    map.key = ["type", "unit"]
    let json: [String: Any] = ["data": ["limits": [
        ["type": "TOKENS_LIMIT", "unit": 3, "percentage": 10],
        ["type": "TOKENS_LIMIT", "unit": 6, "percentage": 20],
    ]]]
    #expect(DescriptorProvider.windows(in: json, map: map).map(\.key)
        == ["TOKENS_LIMIT-3", "TOKENS_LIMIT-6"])
}

@Test("Two list windows sharing a name stay distinct rather than collapsing")
func listWindowsNumberDuplicates() {
    var map = HarnessDescriptor.Quota.Windows()
    map.list = "limits"
    map.key = ["type"]
    let json: [String: Any] = ["limits": [["type": "SAME"], ["type": "SAME"], ["type": "OTHER"]]]
    #expect(DescriptorProvider.windows(in: json, map: map).map(\.key)
        == ["SAME", "SAME-2", "OTHER"])
}

@Test("An unnamed list window is numbered rather than dropped")
func listWindowsWithoutKeys() {
    var map = HarnessDescriptor.Quota.Windows()
    map.list = "limits"
    let json: [String: Any] = ["limits": [["p": 1], ["p": 2]]]
    #expect(DescriptorProvider.windows(in: json, map: map).map(\.key) == ["0", "1"])
}

@Test("Gauges with no reported window length keep the order they were declared in")
func gaugeOrderIsStableWithoutWindowLengths() throws {
    // Copilot reports no window length, so every sort key is equal. An unstable
    // sort would let the menu bar reorder itself between refreshes.
    let descriptor = try #require(
        HarnessCLI.bundledDescriptors().first { $0.id == "copilot" })
    let provider = try #require(DescriptorProvider(descriptor))
    let response: [String: Any] = [
        "copilot_plan": "test_plan",
        "quota_snapshots": [
            "chat": ["has_quota": true, "percent_remaining": 10],
            "completions": ["has_quota": true, "percent_remaining": 20],
            "premium_interactions": ["has_quota": true, "percent_remaining": 30],
        ],
    ]
    let order = try provider.makeSnapshot(response).gauges.map(\.id)
    for _ in 0..<50 {
        #expect(try provider.makeSnapshot(response).gauges.map(\.id) == order)
    }
    #expect(order == ["chat", "completions", "premium_interactions"])
}

@Test("A wrong field path fails the fixture rather than charting nothing")
func quotaFixtureCatchesABrokenMapping() {
    let expected = QuotaFixture.Expectation(
        accountLabel: "pro",
        gauges: [.init(id: "week", badge: "7D", title: "Weekly",
                       usedPercent: 50, windowSeconds: nil, resetsAt: nil)])
    let actual = Snapshot(providerID: "x",
                          gauges: [Gauge(id: "week", badge: "7D", title: "Weekly",
                                         used: 0.25, resetsAt: nil, reportedSeverity: .normal)],
                          extras: [], accountLabel: "pro", fetchedAt: Date())
    let problems = QuotaFixture.differences(expected: expected, actual: actual)
    #expect(problems.count == 1)
    #expect(problems[0].contains("week used"))
}

// MARK: - Credit balances

@Test("A balance carries no meter and never colours itself off a phantom fill")
func balanceGaugeHasNoMeter() {
    let balance = Gauge(id: "credits", badge: "BAL", title: "Credits", used: 0,
                        resetsAt: nil, reportedSeverity: .normal,
                        amount: Gauge.Amount(value: 0.02, currency: "USD"))
    #expect(!balance.hasMeter)
    // `used: 0` would otherwise read as "100% headroom, all is well" — which is
    // exactly the false reassurance a balance-as-percentage gives.
    #expect(balance.severity == .normal)
    #expect(balance.amountText == "$0.02")

    let metered = Gauge(id: "week", badge: "7D", title: "Weekly", used: 0,
                        resetsAt: nil, reportedSeverity: .normal)
    #expect(metered.hasMeter)
    #expect(metered.amountText == nil)
}

@Test("A balance keeps the currency the service reported")
func balanceKeepsItsCurrency() {
    let yuan = Gauge(id: "CNY", badge: "CNY", title: "CNY", used: 0, resetsAt: nil,
                     reportedSeverity: .normal,
                     amount: Gauge.Amount(value: 8.25, currency: "CNY"))
    // No symbol is invented for a currency we cannot render unambiguously.
    #expect(yuan.amountText == "8.25 CNY")
    #expect(Gauge.symbol(for: "usd") == "$")
    #expect(Gauge.symbol(for: "CNY") == nil)
}

@Test("Large balances drop the cents; small ones keep them")
func balanceFormatting() {
    func text(_ value: Double) -> String? {
        Gauge(id: "b", badge: "BAL", title: "B", used: 0, resetsAt: nil,
              reportedSeverity: .normal,
              amount: Gauge.Amount(value: value, currency: "USD")).amountText
    }
    #expect(text(99.5) == "$99.50")
    #expect(text(100) == "$100")
    #expect(text(1234.56) == "$1235")
    #expect(text(0) == "$0.00")
}

@Test("A menu bar row for a balance asks for no bar")
@MainActor
func balanceRowHasNoFill() {
    let snapshot = Snapshot(
        providerID: "vercel-gateway",
        gauges: [Gauge(id: "credits", badge: "BAL", title: "Credits", used: 0,
                       resetsAt: nil, reportedSeverity: .normal,
                       amount: Gauge.Amount(value: 95.5, currency: "USD")),
                 Gauge(id: "week", badge: "7D", title: "Weekly", used: 0.4,
                       resetsAt: nil, reportedSeverity: .normal)],
        extras: [], accountLabel: nil, fetchedAt: Date())
    let rows = StatusRender.rows(for: snapshot)
    #expect(rows[0].fill == nil)
    #expect(rows[0].percentText == "$95.50")
    #expect(rows[1].fill != nil)
}

@Test("A flat response can be one window; a declared envelope that is missing is not the whole reply")
func singleWindowAndMissingEnvelope() {
    var flat = HarnessDescriptor.Quota.Windows()
    flat.single = "credits"
    let found = DescriptorProvider.windows(in: ["balance": 95.5], map: flat)
    #expect(found.count == 1)
    #expect(found[0].key == "credits")

    // A declared root that does not resolve must yield nothing, not the entire
    // response — otherwise every top-level key becomes a candidate window.
    var rooted = HarnessDescriptor.Quota.Windows()
    rooted.roots = ["data.windowLimits", "windowLimits"]
    #expect(DescriptorProvider.windows(in: ["other": ["a": 1]], map: rooted).isEmpty)
    #expect(DescriptorProvider.windows(in: ["windowLimits": ["a": ["used": 1]]], map: rooted)
        .map(\.key) == ["a"])
}

@Test("Currency is read from the window when a path is given, kept literal otherwise")
func currencyResolution() {
    var map = HarnessDescriptor.Quota.Windows()
    #expect(DescriptorProvider.currency(map, window: [:]) == "USD")
    map.currency = "USD"
    #expect(DescriptorProvider.currency(map, window: ["currency": "CNY"]) == "USD")
    map.currency = "currency"
    #expect(DescriptorProvider.currency(map, window: ["currency": "CNY"]) == "CNY")
    // A declared path that resolves to nothing keeps the code asked for rather
    // than silently relabelling the money as dollars.
    #expect(DescriptorProvider.currency(map, window: [:]) == "currency")
}
