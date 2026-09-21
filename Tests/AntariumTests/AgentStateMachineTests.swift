import Foundation
import Testing
@testable import Antarium

/// The one decision every harness goes through.
///
/// It had tests for the ordinary answers and none for the edges, so five
/// regressions in it passed the suite untouched: a remote agent checked for a
/// local process, the idle boundary moved by one comparison, a time that is
/// not a number charted as one, and two rank changes that would silence or
/// invent stop alerts. Each of those is a wrong row rather than a crash,
/// which is why nothing noticed.
@Suite("What state an agent is in")
struct AgentStateMachineTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Compared by label, because `AgentRow.State` is not Equatable and the
    /// label is what a person actually reads on the row.
    private func state(_ build: (inout AgentStateMachine.Evidence) -> Void) -> String {
        var evidence = AgentStateMachine.Evidence()
        build(&evidence)
        return AgentStateMachine.state(evidence, now: now).label
    }

    /// An agent running somewhere else has no local process to check, and
    /// `processAlive` defaults to true — so without the short circuit a cloud
    /// session would be handed to the inference below and reported as
    /// whatever its timestamps suggested, on a machine it is not running on.
    @Test("A remote agent is reported as remote, whatever else is known")
    func remoteShortCircuits() {
        #expect(state { $0.remote = "cloud" } == "Cloud")
        // Even with a published status and a live timestamp, which is the
        // combination that would otherwise win.
        #expect(state {
            $0.remote = "cloud"
            $0.published = .working
            $0.lastActivity = now
        } == "Cloud")
        // And even with no process, which would otherwise be `.ended`.
        #expect(state { $0.remote = "cloud"; $0.processAlive = false } == "Cloud")
    }

    /// The boundary itself. A transcript quiet for exactly the idle period is
    /// still working: the period is how long quiet is tolerated, so the
    /// moment it elapses is the last moment inside it.
    @Test("A transcript quiet for exactly the idle period is still working")
    func idleBoundaryIsExclusive() {
        #expect(state {
            $0.lastActivity = now.addingTimeInterval(-90)
            $0.idleAfter = 90
        } == "Working")
        #expect(state {
            $0.lastActivity = now.addingTimeInterval(-90.001)
            $0.idleAfter = 90
        } == "Waiting")
    }

    /// A timestamp from the future, or an idle period that is not a number,
    /// is not evidence. Reporting "working" from a negative age would make a
    /// clock correction look like activity.
    @Test("A time that is not a number reports unknown rather than working",
          arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteIdleIsUnknown(_ value: Double) {
        #expect(state {
            $0.lastActivity = now.addingTimeInterval(-10)
            $0.idleAfter = value
        } == "Unknown")
    }

    @Test("A timestamp in the future reports unknown rather than working")
    func futureActivityIsUnknown() {
        #expect(state { $0.lastActivity = now.addingTimeInterval(3_600) } == "Unknown")
    }

    /// Except when the agent is looping, where the answer is still that it is
    /// between rounds rather than that nothing is known.
    @Test("A looping agent with unusable times is still looping")
    func loopingSurvivesBadTimes() {
        #expect(state {
            $0.looping = true
            $0.lastActivity = now.addingTimeInterval(3_600)
        } == "Looping")
        #expect(state { $0.looping = true } == "Looping")
    }
}

/// Which states mean an agent is doing something, and which mean it wants
/// you. `AgentStore.stopped` reads this ordering to decide what finished, so
/// a change here silently changes what gets announced.
@Suite("The state ordering decides what counts as finishing")
@MainActor
struct AgentStateRankTests {

    private func row(_ id: String, _ state: AgentRow.State) -> AgentRow {
        AgentRow(id: id, agentID: "x", name: id, cwd: "/synthetic", state: state)
    }

    /// The case the ordering exists for. An agent on a loop of its own pauses
    /// between rounds; if pausing counted as finishing, every iteration would
    /// post an alert and play a sound.
    @Test("A loop pausing between rounds has not finished")
    func loopingIsNotFinishing() {
        let was = ["a": row("a", .working)]
        #expect(AgentStore.stopped(previous: was, current: [row("a", .looping)]).isEmpty,
                "an agent between rounds was announced as stopped")
    }

    /// And a shell is somebody working in a terminal, not a finished session.
    @Test("A shell has not finished either")
    func shellIsNotFinishing() {
        let was = ["a": row("a", .working)]
        #expect(AgentStore.stopped(previous: was, current: [row("a", .shell)]).isEmpty)
    }

    /// The other side: the states that do mean it wants you, and so do mean
    /// the work stopped.
    @Test("Waiting and ending are finishing", arguments: [
        AgentRow.State.waiting, .ended,
    ])
    func waitingAndEndingAreFinishing(_ state: AgentRow.State) {
        let was = ["a": row("a", .working)]
        #expect(AgentStore.stopped(previous: was, current: [row("a", state)]).map(\.id) == ["a"])
    }

    /// A session that stops being observable has not been seen to finish.
    /// Announcing one would turn every unreadable transcript into a
    /// notification.
    @Test("Losing sight of a session is not watching it finish")
    func losingSightIsNotFinishing() {
        let was = ["a": row("a", .working)]
        #expect(AgentStore.stopped(previous: was, current: [row("a", .unobserved)]).isEmpty)
    }

    /// `.cloud` is not excluded the way `.unobserved` is, and would be
    /// announced. That is recorded rather than changed, because the
    /// transition cannot happen: a row has to have been working to be
    /// considered at all, and whether a session is remote is fixed by the id
    /// it is built with — a local row never becomes a cloud one. Excluding it
    /// would add a branch nothing can reach, which is worse than a rule with
    /// a stated edge.
    @Test("A working row turning cloud would count as finishing, and cannot")
    func cloudIsNotExcluded() {
        let was = ["a": row("a", .working)]
        #expect(AgentStore.stopped(previous: was,
                                   current: [row("a", .cloud("host"))]).map(\.id) == ["a"])
        // The half that makes it unreachable: a cloud row is never the
        // previous working state, because its rank is below the threshold.
        #expect(AgentStore.stopped(previous: ["a": row("a", .cloud("host"))],
                                   current: [row("a", .ended)]).isEmpty)
    }

    /// A loop that was looping and is now waiting has finished: the loop
    /// itself came to an end, which is the thing worth telling somebody.
    @Test("A loop that stops looping has finished")
    func loopEndingIsFinishing() {
        let was = ["a": row("a", .looping)]
        #expect(AgentStore.stopped(previous: was, current: [row("a", .waiting)]).map(\.id) == ["a"])
    }
}
