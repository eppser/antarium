import Foundation
import Testing
@testable import Antarium

/// What the dashboard is allowed to keep showing when it stops being able to
/// see. Four mutations of this file survived the first run, all of them the
/// same shape: a row that goes on looking live after the thing behind it
/// became unknowable.
@Suite("Rows do not outlive the ability to observe them", .serialized)
@MainActor
struct AgentStoreMergeTests {

    private func row(_ id: String, _ state: AgentRow.State) -> AgentRow {
        AgentRow(id: id, agentID: "claude-code", name: id, cwd: "/p", state: state)
    }

    // MARK: - A machine that stopped answering

    @Test("A host that did not answer has its rows marked unobserved")
    func silentHostGoesUnobserved() {
        let before = ["alpha": [row("a", .working), row("b", .waiting)]]
        let merged = AgentStore.applyRemote(
            results: [.init(host: "alpha", rows: [], issue: "timed out")],
            to: before, issues: [:], configured: ["alpha"])
        let kept = merged.rows["alpha"] ?? []
        #expect(kept.count == 2, "the rows are kept, because they were real a moment ago")
        for row in kept {
            if case .unobserved = row.state {} else {
                Issue.record("\(row.id) still reads \(row.state) after the host went quiet")
            }
            #expect(row.remoteObservationIssue == "timed out")
        }
    }

    /// A host that comes back must lose its old complaint, or the dashboard
    /// reports a failure that is over.
    @Test("A host that answers again clears its previous problem")
    func recoveredHostClearsItsIssue() {
        let merged = AgentStore.applyRemote(
            results: [.init(host: "alpha", rows: [row("a", .working)], issue: nil)],
            to: ["alpha": [row("a", .unobserved)]],
            issues: ["alpha": "timed out"], configured: ["alpha"])
        #expect(merged.issues["alpha"] == nil, "a stale failure outlived the failure")
        #expect(merged.rows["alpha"]?.first?.remoteObservationIssue == nil)
    }

    @Test("An answer of no agents is a fact, not a failure")
    func emptyAnswerIsNotAFailure() {
        let merged = AgentStore.applyRemote(
            results: [.init(host: "alpha", rows: [], issue: nil)],
            to: ["alpha": [row("a", .working)]], issues: [:], configured: ["alpha"])
        #expect(merged.rows["alpha"]?.isEmpty == true)
        #expect(merged.issues["alpha"] == nil)
    }

    @Test("A host no longer configured takes its rows and its problems with it")
    func removedHostIsForgotten() {
        let merged = AgentStore.applyRemote(
            results: [], to: ["gone": [row("a", .working)]],
            issues: ["gone": "timed out"], configured: ["alpha"])
        #expect(merged.rows["gone"] == nil)
        #expect(merged.issues["gone"] == nil)
    }

    /// The list must not shuffle because a different machine replied first.
    @Test("Rows are ordered by how the hosts are configured, not by who answered")
    func orderFollowsConfiguration() {
        let byHost = ["beta": [row("b1", .waiting)], "alpha": [row("a1", .waiting)]]
        #expect(AgentStore.orderedRemoteRows(hosts: ["alpha", "beta"], rowsByHost: byHost)
            .map(\.id) == ["a1", "b1"])
        #expect(AgentStore.orderedRemoteRows(hosts: ["beta", "alpha"], rowsByHost: byHost)
            .map(\.id) == ["b1", "a1"])
    }

    @Test("A configured host with no rows yet contributes none")
    func unknownHostContributesNothing() {
        #expect(AgentStore.orderedRemoteRows(hosts: ["alpha"], rowsByHost: [:]).isEmpty)
    }

    // MARK: - Which agents are worth announcing as stopped

    /// Announcing a stop for something that was never working is noise, and
    /// noise in a notification is worse than silence.
    @Test("Only an agent that was above the working threshold can stop")
    func onlyWorkingAgentsStop() {
        let was = [row("a", .waiting), row("b", .ended)]
        let previous = Dictionary(was.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let stopped = AgentStore.stopped(previous: previous,
                                         current: [row("a", .ended), row("b", .ended)])
        #expect(stopped.isEmpty)
    }

    @Test("An agent that was working and is now finished has stopped")
    func workingToFinishedStops() {
        let was = row("a", .working)
        let stopped = AgentStore.stopped(previous: [was.id: was], current: [row("a", .waiting)])
        #expect(stopped.map(\.id) == ["a"])
    }

    @Test("An agent that was working and has vanished has stopped")
    func vanishedStops() {
        let was = row("a", .working)
        #expect(AgentStore.stopped(previous: [was.id: was], current: []).map(\.id) == ["a"])
    }

    /// Losing sight of an agent is not the same as it finishing, and saying
    /// so would announce a stop that may not have happened.
    @Test("An agent that became unobservable has not stopped")
    func unobservedDoesNotStop() {
        let was = row("a", .working)
        #expect(AgentStore.stopped(previous: [was.id: was],
                                   current: [row("a", .unobserved)]).isEmpty)
    }

    @Test("An agent still working has not stopped")
    func stillWorkingDoesNotStop() {
        let was = row("a", .working)
        #expect(AgentStore.stopped(previous: [was.id: was],
                                   current: [row("a", .working)]).isEmpty)
    }

    @Test("Nothing is announced on the first reading")
    func firstReadingIsSilent() {
        #expect(AgentStore.stopped(previous: [:], current: [row("a", .ended)]).isEmpty)
    }
}

/// How often the app scans, which is most of what it costs to leave running.
/// Three mutations of this survived: the counter never coming back down, the
/// counter going negative, and the interval ignoring visibility altogether.
/// Each is a laptop that does not idle, and none of them look like a bug.
@Suite("Scan interval follows what is actually being watched", .serialized)
@MainActor
struct ScanIntervalTests {

    @Test("Nothing watching means the interval the user configured")
    func idleUsesTheConfiguredInterval() {
        #expect(AgentStore.scanInterval(visible: 0, configured: 30) == 30)
        #expect(AgentStore.scanInterval(visible: 0, configured: 3) == 3)
    }

    @Test("Something watching scans at most every five seconds")
    func watchedIsCapped() {
        #expect(AgentStore.scanInterval(visible: 1, configured: 30) == 5)
        #expect(AgentStore.scanInterval(visible: 4, configured: 600) == 5)
    }

    /// A user who asked for something faster than the cap gets it. The cap is
    /// a ceiling on the rate, not a floor.
    @Test("A configured interval below the cap is honoured as it stands")
    func fastConfigurationIsNotSlowedDown() {
        #expect(AgentStore.scanInterval(visible: 1, configured: 2) == 2)
    }

    /// The whole point of the counter: what goes up comes back down. A view
    /// that fails to release leaves the app scanning every five seconds for
    /// as long as it runs.
    @Test("Opening and closing a view returns the interval to idle")
    func balancedVisibilityReturnsToIdle() {
        let store = AgentStore()
        #expect(store.visibleObservers == 0)
        store.setVisible(true)
        store.setVisible(true)
        #expect(store.visibleObservers == 2)
        store.setVisible(false)
        store.setVisible(false)
        #expect(store.visibleObservers == 0, "a view held the fast interval after closing")
    }

    /// And an unbalanced close cannot drive it below zero, which would make
    /// the next open a no-op — the dashboard refreshing at the idle rate
    /// while someone is looking at it.
    @Test("An unbalanced close does not make the next open a no-op")
    func countCannotGoNegative() {
        let store = AgentStore()
        store.setVisible(false)
        store.setVisible(false)
        #expect(store.visibleObservers == 0)
        store.setVisible(true)
        #expect(store.visibleObservers == 1)
        #expect(AgentStore.scanInterval(visible: store.visibleObservers,
                                        configured: 30) == 5)
    }
}
