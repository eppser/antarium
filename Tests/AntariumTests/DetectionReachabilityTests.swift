import Foundation
import Testing
@testable import Antarium

/// Whether every agent this app ships can actually be found by the first run.
///
/// The detection policy is well covered — what `resolve` does with evidence,
/// how ties break, what the cap does. What nothing asked was the question
/// underneath it: given the providers that ship, is there any machine state
/// at all that would get each of them switched on? A provider nothing can
/// detect is a provider the user installs Antarium beside, has running, and
/// never sees — and no test of the policy would notice, because the policy
/// is correct about evidence it is never given.
///
/// Read from the bundle rather than the registry, because the registry is
/// native providers plus whatever this Mac's descriptor folder holds.
@Suite("Every shipped agent can be found by a first run")
struct DetectionReachabilityTests {

    private var bundled: [HarnessDescriptor] { HarnessCLI.bundledDescriptors() }

    /// What ships: the native providers plus every bundled descriptor that
    /// declares a quota. The same set `AgentAutoEnable` is handed on a first
    /// run.
    private var shippedIDs: [String] {
        Set(ProviderRegistry.providers(from: bundled).map(\.id))
            .union(ProviderRegistry.nativeIDs)
            .sorted()
    }

    @Test("Something ships, so the assertions below are about a real set")
    func somethingShips() {
        #expect(shippedIDs.count >= 14,
                Comment(rawValue: "only \(shippedIDs.count) providers ship"))
    }

    /// Nothing is dropped between the registry and the ranking.
    @Test("Every shipped provider is given a place in the evidence")
    func everyProviderIsWeighed() {
        let ids = shippedIDs
        let evidence = AgentAutoEnable.evidence(
            providers: ids.map { (id: $0, signedIn: false) }, sessionsPresent: [])
        #expect(Set(evidence.map(\.id)) == Set(ids),
                "a provider the app ships never reaches the ranking")
    }

    /// And none is structurally excluded from winning. A provider that can be
    /// weighed but can never place is detected in name only.
    @Test("Any shipped provider alone on a Mac is the one enabled")
    func anyProviderCanBeEnabled() {
        for id in shippedIDs {
            let evidence = AgentAutoEnable.evidence(
                providers: [(id: id, signedIn: true)], sessionsPresent: [id])
            #expect(AgentAutoEnable.resolve(evidence, fallback: ["other"]) == [id],
                    Comment(rawValue: "\(id) is the only agent present and was not enabled"))
        }
    }

    /// Both halves of the evidence can carry a provider on their own, so a
    /// service with a credential but no session store — and an agent with
    /// sessions but no account — are each still findable.
    @Test("Either half of the evidence is enough on its own")
    func eitherSignalSuffices() {
        for id in shippedIDs {
            let signedInOnly = AgentAutoEnable.evidence(
                providers: [(id: id, signedIn: true)], sessionsPresent: [])
            #expect(AgentAutoEnable.resolve(signedInOnly, fallback: ["other"]) == [id],
                    Comment(rawValue: "\(id) is signed in and was not enabled"))

            let sessionsOnly = AgentAutoEnable.evidence(
                providers: [(id: id, signedIn: false)], sessionsPresent: [id])
            #expect(AgentAutoEnable.resolve(sessionsOnly, fallback: ["other"]) == [id],
                    Comment(rawValue: "\(id) has sessions on disk and was not enabled"))
        }
    }

    /// The other direction, and the one that costs a user a slot.
    ///
    /// `DescriptorProvider.probeConfigured` answers `true` for a quota that
    /// declares no credential — deliberately, since an endpoint needing no
    /// credential is a real thing. But "signed in" is evidence, and a
    /// provider that reports it unconditionally reports it on every Mac,
    /// including one whose owner has never heard of the service. A first run
    /// switches on four agents; one taken by a service nobody uses is one an
    /// agent they do use did not get.
    ///
    /// Nothing that ships does this today. The assertion is what keeps it
    /// that way, because the descriptor that would is a two-line file.
    @Test("No shipped quota reports itself configured without evidence")
    func noQuotaClaimsConfiguredForFree() {
        for descriptor in bundled where descriptor.quota != nil {
            let quota = descriptor.quota!
            #expect(quota.credential != nil || quota.command != nil,
                    Comment(rawValue: "\(descriptor.id) declares a quota with neither a "
                            + "credential nor a command, so it reports itself signed in "
                            + "on every Mac and competes for a first-run slot everywhere"))
        }
    }

    /// A credential that is a command is evidence that the program is
    /// installed; one that is a file or an environment variable is evidence
    /// the account exists. Either is a real reading of the machine — an
    /// unrecognised kind would not be, and would fall through to `token()`.
    @Test("Every shipped credential is a kind detection understands")
    func credentialKindsAreKnown() {
        let known: Set<String> = ["command", "jsonFile", "textFile", "env", "keychain"]
        for descriptor in bundled {
            guard let kind = descriptor.quota?.credential?.kind else { continue }
            #expect(known.contains(kind),
                    Comment(rawValue: "\(descriptor.id) uses credential kind \(kind), "
                            + "which detection does not recognise"))
        }
    }

    /// The cap is a policy about crowding, not a reason an agent is missing:
    /// with more agents present than slots, the ones left out must be exactly
    /// the weakest, and every one of them must still be offered in Settings.
    @Test("A Mac with everything installed enables the cap, not fewer")
    func crowdedMacFillsTheCap() {
        let ids = shippedIDs
        let evidence = AgentAutoEnable.evidence(
            providers: ids.map { (id: $0, signedIn: true) }, sessionsPresent: Set(ids))
        let enabled = AgentAutoEnable.resolve(evidence, fallback: [])
        #expect(enabled.count == AgentAutoEnable.limit,
                Comment(rawValue: "\(enabled.count) enabled against a cap of "
                        + "\(AgentAutoEnable.limit)"))
        #expect(enabled.isSubset(of: Set(ids)))
    }
}
