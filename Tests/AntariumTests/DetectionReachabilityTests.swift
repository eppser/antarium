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
        // Seventeen ship. The floor was fourteen, which left three free to
        // disappear unnoticed — and moonshot, openrouter and synthetic are
        // exactly three.
        #expect(shippedIDs.count >= 17,
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

    /// The credential kinds `DescriptorProvider.token()` actually implements.
    ///
    /// This list was written from what sounded reasonable and included
    /// "keychain", which `token()` does not implement: its switch handles
    /// env, command, textFile and jsonFile, and everything else falls to
    /// `default: return nil`. A descriptor using an unimplemented kind
    /// reports `isConfigured == false` on every Mac, so it could never be
    /// auto-enabled — the precise failure this suite exists to prevent — and
    /// the test blessed it. A set the test invents is a second opinion;
    /// these four are the ones the code has branches for.
    @Test("Every shipped credential is a kind the token reader implements")
    func credentialKindsAreKnown() {
        let implemented: Set<String> = ["env", "command", "textFile", "jsonFile"]
        var seen = 0
        for descriptor in bundled {
            guard let kind = descriptor.quota?.credential?.kind else { continue }
            seen += 1
            #expect(implemented.contains(kind),
                    Comment(rawValue: "\(descriptor.id) uses credential kind \(kind), which "
                            + "token() does not implement — it would read as not configured "
                            + "on every Mac and could never be auto-enabled"))
        }
        // Or the loop above skipped everything and asserted nothing.
        #expect(seen >= 10, Comment(rawValue: "only \(seen) credentials were examined"))
    }

    /// What each credential kind needs before it can produce a token at all.
    ///
    /// This is the assertion the rest of this suite was missing. Everything
    /// above hands `AgentAutoEnable` a `signedIn:` this test made up, and
    /// `resolve` treats every id alike apart from the tie-break — so looping
    /// all seventeen providers proved nothing that one would not have. None
    /// of it read the shipped data.
    ///
    /// `DescriptorProvider.token()` needs particular fields per kind, and a
    /// credential missing one returns nil on every Mac rather than failing
    /// visibly: `env` needs a variable name or a file to fall back to,
    /// `command` a command, `textFile` a path, `jsonFile` a path and the
    /// field to read out of it. A descriptor that omits one is a provider
    /// that can never be signed in, never auto-enabled, and whose setup hint
    /// tells the user to do something that will not help.
    @Test("Every shipped credential declares what its kind needs to read a token")
    func credentialsCanProduceAToken() {
        var checked = 0
        for descriptor in bundled {
            guard let credential = descriptor.quota?.credential else { continue }
            checked += 1
            let id = descriptor.id
            switch credential.kind {
            case "env":
                // Either route: the variable a terminal launch has, or the
                // file a Finder launch falls back to.
                #expect(credential.name != nil || credential.path != nil,
                        Comment(rawValue: "\(id) reads an env credential and names neither a "
                                + "variable nor a fallback file, so it can never find one"))
            case "command":
                #expect(credential.command?.isEmpty == false,
                        Comment(rawValue: "\(id) reads a command credential and names no command"))
            case "textFile":
                #expect(credential.path?.isEmpty == false,
                        Comment(rawValue: "\(id) reads a text credential and names no path"))
            case "jsonFile":
                #expect(credential.path?.isEmpty == false,
                        Comment(rawValue: "\(id) reads a JSON credential and names no path"))
                #expect(credential.field?.isEmpty == false,
                        Comment(rawValue: "\(id) reads a JSON credential and names no field, "
                                + "so there is nothing to look up in it"))
            default:
                Issue.record(Comment(rawValue: "\(id) uses credential kind \(credential.kind), "
                                     + "which token() has no branch for"))
            }
        }
        #expect(checked >= 10, Comment(rawValue: "only \(checked) credentials were examined"))
    }

    /// And the same for a quota that reads its figures from a program: a
    /// command that is not named cannot resolve, so `probeConfigured`
    /// reports not-installed for ever.
    @Test("Every shipped command quota names a command to run")
    func commandQuotasNameACommand() {
        for descriptor in bundled {
            guard let command = descriptor.quota?.command else { continue }
            #expect(!command.isEmpty,
                    Comment(rawValue: "\(descriptor.id) reads its quota from a command and "
                            + "names no program, so it can never be detected"))
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
        // The cap's value, which nothing pinned. Six assertions across four
        // files compare against `AgentAutoEnable.limit` symbolically, so a
        // cap of one satisfied every one of them: a first run enabling a
        // single agent on a Mac with eight installed would have passed.
        #expect(AgentAutoEnable.limit == 4,
                Comment(rawValue: "the first-run cap is \(AgentAutoEnable.limit)"))
        #expect(enabled.count < ids.count, "every agent was enabled, so the cap did nothing")
    }
}
