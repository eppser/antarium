import Foundation
import Testing
@testable import Antarium

/// The first run's promise, across launches: the bar configures itself from
/// what is installed, and never argues with a choice the user has made.
///
/// Driven through the pure record functions rather than through settings on
/// disk. `Config` binds its path the first time it is touched, so pointing
/// `ANTARIUM_HOME` at a temporary directory mid-process does nothing — the
/// first attempt at this read the developer's own agents and passed.
///
/// `resolve` and `adoptions` were already covered on their own. What was not
/// is the bookkeeping that ties launches together: `known` is how a later
/// launch tells an agent that shipped since from one the user turned off, and
/// a run that chooses without recording it looks perfectly correct while
/// disabling adoption for ever.
@Suite("Across launches, the bar configures itself without overruling anyone")
struct FirstRunLifecycleTests {

    /// One install's settings as they would be on disk between launches.
    private struct Install {
        var enabled: Set<String>?
        var known: Set<String> = []

        mutating func launch(_ agents: [(id: String, signedIn: Bool, sessions: Bool)]) {
            let evidence = agents.map {
                AgentAutoEnable.Evidence(id: $0.id, signedIn: $0.signedIn,
                                         hasSessions: $0.sessions)
            }
            if let record = AgentAutoEnable.firstRunRecord(
                recorded: enabled.map { Array($0).sorted() },
                evidence: evidence, fallback: agents.map(\.id)) {
                enabled = record.enabled
                known = record.known
                return
            }
            let record = AgentAutoEnable.adoptionRecord(
                known: known, enabled: enabled ?? [],
                providers: agents.map { ($0.id, $0.signedIn) })
            enabled = (enabled ?? []).union(record.adopted)
            known = record.known
        }

        /// What the user does in Settings.
        mutating func userSwitchesOff(_ id: String) { enabled?.remove(id) }
    }

    private func agent(_ id: String, signedIn: Bool = true, sessions: Bool = false)
        -> (id: String, signedIn: Bool, sessions: Bool) { (id, signedIn, sessions) }

    @Test("A first launch enables what is installed and records everything it saw")
    func firstLaunch() {
        var install = Install()
        install.launch([agent("a"), agent("b"), agent("c", signedIn: false)])
        #expect(install.enabled == ["a", "b"], "c showed no evidence at all")
        #expect(install.known == ["a", "b", "c"],
                "an agent seen and passed over must still count as seen")
    }

    @Test("A second launch changes nothing")
    func secondLaunchIsQuiet() {
        var install = Install()
        let agents = [agent("a"), agent("b")]
        install.launch(agents)
        install.launch(agents)
        #expect(install.enabled == ["a", "b"])
    }

    @Test("An agent that ships later and is signed in is adopted")
    func laterAgentAdopted() {
        var install = Install()
        install.launch([agent("a")])
        install.launch([agent("a"), agent("new")])
        #expect(install.enabled == ["a", "new"])
    }

    /// The other half of the ask. Automatic configuration must never undo a
    /// deliberate one: an agent the user switched off has been seen, so it is
    /// not new, however plainly it is installed.
    @Test("An agent the user switched off never comes back")
    func rejectionSticks() {
        var install = Install()
        install.launch([agent("a"), agent("b")])
        install.userSwitchesOff("b")
        install.launch([agent("a"), agent("b")])
        #expect(install.enabled == ["a"], "b switched itself back on")
    }

    @Test("An agent adopted and then switched off does not return either")
    func adoptedThenRejected() {
        var install = Install()
        install.launch([agent("a")])
        install.launch([agent("a"), agent("new")])
        install.userSwitchesOff("new")
        install.launch([agent("a"), agent("new")])
        #expect(install.enabled == ["a"])
    }

    @Test("An agent that ships later but is not signed in is left alone")
    func unsignedIsNotAdopted() {
        var install = Install()
        install.launch([agent("a")])
        install.launch([agent("a"), agent("new", signedIn: false, sessions: true)])
        #expect(install.enabled == ["a"], "that item could only say sign in")
    }

    @Test("Adoption cannot fill a bar the first run deliberately capped")
    func adoptionRespectsTheCap() {
        var install = Install()
        let full = (0..<AgentAutoEnable.limit).map { agent("a\($0)") }
        install.launch(full)
        #expect(install.enabled?.count == AgentAutoEnable.limit)
        install.launch(full + [agent("new")])
        #expect(install.enabled?.count == AgentAutoEnable.limit)
    }

    /// An install predating `knownAgents` cannot tell a new agent from a
    /// rejected one, so it records what it sees and adopts nothing.
    @Test("An upgrade with a choice but no record adopts nothing, then starts recording")
    func upgradeIsQuietOnce() {
        var install = Install(enabled: ["a"], known: [])
        install.launch([agent("a"), agent("b")])
        #expect(install.enabled == ["a"], "b was adopted before it could be told from a rejection")
        #expect(install.known == ["a", "b"])
        install.launch([agent("a"), agent("b")])
        #expect(install.enabled == ["a"], "and still not on the launch after")
    }

    @Test("A bar with nothing installed still gets one item, so there is a way back in")
    func emptyMachineIsNotAnEmptyBar() {
        var install = Install()
        install.launch([agent("a", signedIn: false), agent("b", signedIn: false)])
        #expect(install.enabled?.count == 1)
    }
}
