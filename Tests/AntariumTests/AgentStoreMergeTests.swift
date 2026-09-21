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

/// When the app reaches out to other machines. A sweep opens an SSH session
/// to every configured host, so three of these four rules are about *not*
/// connecting — and the one that matters most is that switching the feature
/// off stops it. All four mutations of this survived before these existed.
@Suite("Remote sweeps happen when they are meant to", .serialized)
@MainActor
struct RemoteSweepGatingTests {

    private let hosts = ["alpha", "beta"]

    /// The rule a user relies on when they untick the box. Continuing to
    /// connect to someone's machines after they switched it off is not a
    /// performance problem.
    @Test("Switched off means stop, not merely stop starting new ones")
    func disabledCancels() {
        #expect(AgentStore.remoteSweep(enabled: false, hosts: hosts, running: false,
                                       force: true, sinceLastAttempt: 9_999) == .cancel)
        #expect(AgentStore.remoteSweep(enabled: false, hosts: hosts, running: true,
                                       force: true, sinceLastAttempt: 9_999) == .cancel,
                "a sweep already in flight must be dropped too")
    }

    @Test("No configured hosts is the same as switched off")
    func noHostsCancels() {
        #expect(AgentStore.remoteSweep(enabled: true, hosts: [], running: false,
                                       force: true, sinceLastAttempt: 9_999) == .cancel)
    }

    /// Without this the sweep runs on every local scan — every five seconds
    /// while the dashboard is open — instead of every thirty, which is six
    /// times the SSH traffic to somebody else's machines.
    @Test("A sweep too soon after the last one is skipped")
    func tooSoonIsSkipped() {
        #expect(AgentStore.remoteSweep(enabled: true, hosts: hosts, running: false,
                                       force: false, sinceLastAttempt: 5) == .skip)
        #expect(AgentStore.remoteSweep(enabled: true, hosts: hosts, running: false,
                                       force: false, sinceLastAttempt: 29.9) == .skip)
    }

    @Test("A sweep at or past the interval runs")
    func dueRuns() {
        #expect(AgentStore.remoteSweep(enabled: true, hosts: hosts, running: false,
                                       force: false, sinceLastAttempt: 30) == .run)
        #expect(AgentStore.remoteSweep(enabled: true, hosts: hosts, running: false,
                                       force: false, sinceLastAttempt: 3_600) == .run)
    }

    /// Asking explicitly — opening the dashboard — skips the wait, because
    /// the interval exists to stop background polling rather than to make
    /// somebody wait for something they just asked for.
    @Test("An explicit refresh does not wait for the interval")
    func forceRunsImmediately() {
        #expect(AgentStore.remoteSweep(enabled: true, hosts: hosts, running: false,
                                       force: true, sinceLastAttempt: 0) == .run)
    }

    /// Even when asked explicitly: a second sweep while one is in flight
    /// doubles the connections to every host and races its own results.
    @Test("One sweep at a time, however it was asked for")
    func runningBlocksAnother() {
        #expect(AgentStore.remoteSweep(enabled: true, hosts: hosts, running: true,
                                       force: true, sinceLastAttempt: 9_999) == .skip)
    }
}

/// A sweep takes seconds. What happens when the setting changes while one is
/// in flight is a separate question from whether to start one, asked after
/// the connections have already been made.
@Suite("Results arriving after the feature was switched off are discarded")
@MainActor
struct RemoteCompletionTests {

    @Test("Results are shown while the feature is on and hosts are configured")
    func ordinaryCompletion() {
        #expect(AgentStore.shouldApplyRemote(enabled: true, hosts: ["alpha"]))
    }

    @Test("Results are discarded when the feature was switched off mid-sweep")
    func switchedOffMidSweep() {
        #expect(!AgentStore.shouldApplyRemote(enabled: false, hosts: ["alpha"]))
    }

    /// And when the last host was removed while the sweep was running, there
    /// is nothing those rows belong to.
    @Test("Results are discarded when the last host was removed mid-sweep")
    func hostsRemovedMidSweep() {
        #expect(!AgentStore.shouldApplyRemote(enabled: true, hosts: []))
    }
}
