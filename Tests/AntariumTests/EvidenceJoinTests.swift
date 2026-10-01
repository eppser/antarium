import Foundation
import Testing
@testable import Antarium

/// Whether the first run can see an agent at all.
///
/// `AgentAutoEnable.evidence` maps over providers and asks
/// `sessionsPresent.contains(provider.id)`. Both halves key on
/// `descriptor.id` — `providers(from:)` and `Onboarding.harnesses` each build
/// their entries from it — so the identifiers cannot disagree, and a test
/// asserting they match would be asserting the construction.
///
/// What can go wrong is an agent falling out of the sessions half entirely.
/// `Onboarding.harnesses` skips a descriptor whose `source.path` is empty and
/// takes a different route for one that contributes presence only, so an agent
/// can be absent from that list while shipping perfectly well. Then
/// `contains` is false on every machine, the agent never reaches the strongest
/// rank, and nothing looks wrong: it still earns a slot on its credential
/// alone, one rank lower, competing against three others.
///
/// This matters for two of the shipped harnesses now. `opencode` and `kimi`
/// read both a session store and a quota, so they are the only ones for which
/// the strongest rank is reachable at all.
@Suite("The first run can see every agent it ships")
struct EvidenceJoinTests {

    private var descriptors: [HarnessDescriptor] { HarnessCLI.bundledDescriptors() }

    /// Agents that read both a session store and a quota.
    private var bothKinds: [HarnessDescriptor] {
        descriptors.filter { $0.quota != nil && $0.source.kind != .none }
    }

    /// The claim that is not construction: every descriptor that declares a
    /// session store is reported by the half that looks for one.
    ///
    /// Checked against the shipped catalogue rather than against a machine, so
    /// it says the same thing on a Mac with no agents installed as on one with
    /// all of them — `found` is what varies by machine, being listed is not.
    @Test("Every agent with a session store is listed by the half that looks for one")
    func sessionHalfCoversItsAgents() {
        let listed = Set(Onboarding.harnesses(descriptors).map(\.id))
        let declared = descriptors.filter { !$0.source.path.isEmpty }.map(\.id)
        #expect(!declared.isEmpty, "no descriptor declares a session store")
        let missing = declared.filter { !listed.contains($0) }.sorted()
        #expect(missing.isEmpty,
                Comment(rawValue: "\(missing.joined(separator: ", ")) declare a session store "
                        + "and are not listed, so the first run can only ever see their "
                        + "credential"))
    }

    /// And the agents that can reach the top rank are listed, specifically.
    /// They are the two the rank exists for.
    @Test("The agents that read both are in both halves")
    func bothKindsAreInBothHalves() throws {
        let listed = Set(Onboarding.harnesses(descriptors).map(\.id))
        let providers = Set(ProviderRegistry.providers(from: descriptors).map(\.id))
            .union(ProviderRegistry.nativeIDs)
        let shipped = bothKinds
        #expect(shipped.count >= 2,
                Comment(rawValue: "\(shipped.count) descriptors read both sessions and a quota"))
        for descriptor in shipped {
            #expect(listed.contains(descriptor.id),
                    Comment(rawValue: "\(descriptor.id) reads sessions and is not in the "
                            + "sessions half"))
            #expect(providers.contains(descriptor.id),
                    Comment(rawValue: "\(descriptor.id) declares a quota and no provider "
                            + "carries its id"))
        }
    }

    /// Both halves reporting one agent is the strongest evidence there is,
    /// driven through `evidence` rather than asserted about `strength` alone.
    @Test("Both halves reporting one agent is the strongest evidence there is")
    func joinReachesTheTop() throws {
        let descriptor = try #require(bothKinds.first,
                                      "no descriptor reads both sessions and a quota")
        let found = AgentAutoEnable.evidence(
            providers: [(id: descriptor.id, signedIn: true)],
            sessionsPresent: [descriptor.id])
        #expect(try #require(found.first).strength == 3)
    }

    /// The failure this guards, written out: an agent whose halves name
    /// different strings ranks lower than one whose halves agree, and both look
    /// like reasonable rows in the settings list.
    @Test("Halves that name different strings silently lose a rank")
    func mismatchCostsARank() {
        let matched = AgentAutoEnable.evidence(providers: [(id: "agent", signedIn: true)],
                                               sessionsPresent: ["agent"])
        let mismatched = AgentAutoEnable.evidence(providers: [(id: "agent", signedIn: true)],
                                                  sessionsPresent: ["agent-cli"])
        #expect(matched.first?.strength == 3)
        #expect(mismatched.first?.strength == 2)
        // Both are still present, which is why the mismatch is invisible.
        #expect(matched.first?.present == true)
        #expect(mismatched.first?.present == true)
    }

    /// A rank lost is a slot lost, not merely a lower number. Four slots, and
    /// an agent that should have ranked highest losing to three that did.
    @Test("A lost rank can cost the slot")
    func aLostRankCostsTheSlot() {
        // Four agents signed in and nothing more, and one signed in *and* used
        // here. The fifth outranks them, and its name sorts last — so its slot
        // is owed to the rank alone, which is the point.
        let others: [(id: String, signedIn: Bool)] =
            [("a", true), ("b", true), ("c", true), ("d", true)]
        let halvesAgree = AgentAutoEnable.resolve(
            AgentAutoEnable.evidence(providers: [("wanted", true)] + others,
                                     sessionsPresent: ["wanted"]),
            fallback: ["a"])
        #expect(halvesAgree.contains("wanted"))
        // The same machine, with only this agent's two halves failing to meet.
        let halvesMiss = AgentAutoEnable.resolve(
            AgentAutoEnable.evidence(providers: [("wanted", true)] + others,
                                     sessionsPresent: ["wanted-cli"]),
            fallback: ["a"])
        #expect(!halvesMiss.contains("wanted"),
                "the four that kept their rank should have taken the slots")
        #expect(halvesMiss.count == AgentAutoEnable.limit)
    }

    /// Kimi in particular, because its quota arrived after this join existed
    /// and is what prompted the suite: one harness, sessions from this Mac and
    /// plan windows from the service, under one id.
    @Test("Kimi's sessions and its plan are one agent")
    func kimiIsOneAgent() throws {
        let kimi = try #require(descriptors.first { $0.id == "kimi" })
        #expect(kimi.quota != nil, "the plan reader is gone")
        #expect(kimi.source.kind != .none, "the session reader is gone")
        #expect(ProviderRegistry.providers(from: descriptors).filter { $0.id == "kimi" }.count == 1)
        #expect(Onboarding.harnesses(descriptors).contains { $0.id == "kimi" })
    }
}
