import Foundation
import Testing
@testable import Antarium

/// The line a user reads to understand why their menu bar looks the way it does.
///
/// `--detect-agents` printed "sessions here" for every agent whose evidence was
/// found, which includes `gemini` — declared `contributes: presence`, keeping no
/// session record at all. `Onboarding` writes "no session record" into the detail
/// beside it, so two lines of one report disagreed and the one a user reads was
/// the untrue one.
///
/// Found by running the built app rather than by reading it. Nothing in the
/// gates looks at what this report says.
@Suite("The first-run report says what kind of evidence it found")
struct EvidenceSummaryTests {

    private func evidence(_ id: String, signedIn: Bool, sessions: Bool)
        -> AgentAutoEnable.Evidence {
        AgentAutoEnable.Evidence(id: id, signedIn: signedIn, hasSessions: sessions)
    }

    private func summary(signedIn: Bool, sessions: Bool, keepsSessions: Bool) -> String {
        HarnessCLI.evidenceSummary(evidence("a", signedIn: signedIn, sessions: sessions),
                                   keepsSessions: keepsSessions)
    }

    /// The defect, stated as the sentence it printed.
    @Test("An agent that keeps no session record is described as installed, not used")
    func presenceOnlyIsInstalled() {
        #expect(summary(signedIn: false, sessions: true, keepsSessions: false)
                == "installed here, not signed in")
        #expect(summary(signedIn: true, sessions: true, keepsSessions: false)
                == "signed in, installed here")
    }

    @Test("An agent that does keep sessions is still described as having them")
    func sessionKeeperIsUnchanged() {
        #expect(summary(signedIn: false, sessions: true, keepsSessions: true)
                == "sessions here, not signed in")
        #expect(summary(signedIn: true, sessions: true, keepsSessions: true)
                == "signed in, sessions here")
    }

    /// A credential with no other evidence says nothing about sessions either
    /// way, so the wording does not change with the harness.
    @Test("A credential alone reads the same whichever kind of harness it is")
    func signedInAlone() {
        #expect(summary(signedIn: true, sessions: false, keepsSessions: true) == "signed in")
        #expect(summary(signedIn: true, sessions: false, keepsSessions: false) == "signed in")
    }

    @Test("No evidence at all is the absent wording, whichever kind it is")
    func noEvidence() {
        #expect(summary(signedIn: false, sessions: false, keepsSessions: true) == Onboarding.absent)
        #expect(summary(signedIn: false, sessions: false, keepsSessions: false) == Onboarding.absent)
    }

    /// No summary claims sessions for a harness that keeps none — the whole
    /// point, asserted over every combination rather than case by case.
    @Test("Nothing claims sessions for a harness that keeps none")
    func neverClaimsSessions() {
        for signedIn in [true, false] {
            for sessions in [true, false] {
                let text = summary(signedIn: signedIn, sessions: sessions, keepsSessions: false)
                #expect(!text.contains("sessions"),
                        Comment(rawValue: "signedIn \(signedIn), evidence \(sessions): \(text)"))
            }
        }
    }

    /// And the shipped descriptor this is about, so the suite is tied to the
    /// fact rather than to a flag someone might flip.
    @Test("Gemini is the harness that keeps no session record")
    func geminiIsThePresenceOnlyOne() throws {
        let presenceOnly = HarnessCLI.bundledDescriptors()
            .filter(\.contributesPresenceOnly).map(\.id).sorted()
        #expect(presenceOnly == ["gemini"],
                Comment(rawValue: "presence-only harnesses: \(presenceOnly)"))
        let gemini = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "gemini" })
        #expect(gemini.source.path.isEmpty, "a presence-only harness reads no path")
        #expect(HarnessCLI.evidenceSummary(
            evidence(gemini.id, signedIn: false, sessions: true),
            keepsSessions: !gemini.contributesPresenceOnly) == "installed here, not signed in")
    }

    /// The set the report is built from, asked directly: `gemini` is out of it
    /// and everything else is in. Without this the filter could be dropped and
    /// only a reader of stdout would notice.
    @Test("The session-keeping set excludes the presence-only harness and nothing else")
    func sessionKeepingSet() {
        let all = HarnessCLI.bundledDescriptors()
        let keeping = HarnessCLI.sessionKeepingIDs(all)
        #expect(!keeping.contains("gemini"),
                "the harness that keeps no session record is in the session-keeping set")
        #expect(keeping.count == all.count - 1,
                Comment(rawValue: "\(keeping.count) of \(all.count) harnesses are in the set"))
        for descriptor in all where descriptor.contributesPresenceOnly {
            #expect(!keeping.contains(descriptor.id),
                    Comment(rawValue: "\(descriptor.id) keeps no sessions and is in the set"))
        }
    }

    /// Every other shipped harness keeps sessions or is focus-only, so the
    /// wording above costs the collection nothing.
    @Test("Every other shipped harness is described as keeping sessions")
    func everyOtherHarnessKeepsSessions() {
        var checked = 0
        for descriptor in HarnessCLI.bundledDescriptors() where !descriptor.contributesPresenceOnly {
            checked += 1
            let text = HarnessCLI.evidenceSummary(
                evidence(descriptor.id, signedIn: false, sessions: true), keepsSessions: true)
            #expect(text == "sessions here, not signed in")
        }
        #expect(checked > 20, Comment(rawValue: "only \(checked) harnesses were checked"))
    }
}
