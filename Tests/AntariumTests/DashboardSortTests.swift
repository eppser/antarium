import Foundation
import Testing
@testable import Antarium

/// The order of the dashboard. Every mode breaks ties the same way — status,
/// then recency — and that is not decoration: without it, rows with equal
/// keys swap places between scans, which is the third instance of unstable
/// ordering found this week.
@Suite("Dashboard order", .serialized)
struct DashboardSortTests {

    private func row(_ cwd: String, agent: String = "claude-code",
                     state: AgentRow.State = .waiting,
                     activity: TimeInterval = 0, host: String? = nil,
                     cost: Double? = nil) -> AgentRow {
        var row = AgentRow(id: UUID().uuidString, agentID: agent, name: "s",
                           cwd: cwd, state: state)
        row.lastActivity = Date(timeIntervalSince1970: 1_800_000_000 + activity)
        row.hostApp = host
        row.costUSD = cost
        return row
    }

    // MARK: - By name

    /// Read as an index, so case must not split the alphabet in two. Plain
    /// comparison puts every capital before every lowercase, so "Zebra" would
    /// come before "apple".
    @Test("Names sort as a reader expects, regardless of case")
    func nameIsCaseInsensitive() {
        // `coreName` lifts an all-lowercase directory but preserves existing
        // capitals, so a name like `iOS-app` keeps its leading lowercase —
        // which is where plain comparison diverges, putting every capital
        // ahead of every lowercase and landing it after "Zebra".
        let rows = [row("/p/Zebra"), row("/p/iOS-app"), row("/p/mango")]
        #expect(AgentScan.sorted(rows, by: .name).map(\.coreName)
                == ["iOS-app", "Mango", "Zebra"])
    }

    /// Two checkouts of the same project, or one repo open in two terminals,
    /// share a name. Status decides, then recency — and the same input must
    /// give the same answer every scan.
    @Test("Rows with the same name are ordered by status, then recency")
    func equalNamesBreakTiesConsistently() {
        let waiting = row("/p/same", state: .waiting, activity: 0)
        let working = row("/p/same", state: .working, activity: 0)
        let ordered = AgentScan.sorted([working, waiting], by: .name)
        #expect(ordered.first?.id == waiting.id, "waiting outranks working in the list order")

        let older = row("/p/same", state: .waiting, activity: 0)
        let newer = row("/p/same", state: .waiting, activity: 60)
        #expect(AgentScan.sorted([older, newer], by: .name).first?.id == newer.id)
    }

    @Test("The same rows sort the same way twice")
    func sortIsStable() {
        let rows = (0..<8).map { row("/p/same", state: .waiting, activity: Double($0 % 3)) }
        let first = AgentScan.sorted(rows, by: .name).map(\.id)
        #expect(AgentScan.sorted(rows, by: .name).map(\.id) == first)
    }

    // MARK: - By harness

    @Test("Grouping by agent puts each agent's rows together")
    func harnessGroups() {
        let rows = [row("/p/a", agent: "codex"), row("/p/b", agent: "claude-code"),
                    row("/p/c", agent: "codex"), row("/p/d", agent: "claude-code")]
        let agents = AgentScan.sorted(rows, by: .harness).map(\.agentID)
        #expect(agents == ["claude-code", "claude-code", "codex", "codex"],
                "rows from one agent were split apart")
    }

    // MARK: - By host

    /// An agent whose terminal is unknown sorts last rather than under an
    /// empty heading.
    @Test("Rows with no known host sort after those that have one")
    func unknownHostSortsLast() {
        let rows = [row("/p/a", host: nil), row("/p/b", host: "Warp"),
                    row("/p/c", host: "tmux")]
        #expect(AgentScan.sorted(rows, by: .host).map { $0.hostApp ?? "—" }
                == ["tmux", "Warp", "—"])
    }

    // MARK: - By spend

    /// A row with no cost is not a row costing nothing: it sorts below a
    /// measured zero rather than tying with it.
    @Test("Unpriced rows sort below a measured zero")
    func unpricedSortsBelowZero() {
        let priced = row("/p/a", cost: 0), unpriced = row("/p/b", cost: nil)
        #expect(AgentScan.sorted([unpriced, priced], by: .spend).first?.id == priced.id)
        let expensive = row("/p/c", cost: 12.5)
        #expect(AgentScan.sorted([priced, expensive, unpriced], by: .spend)
                .map(\.costUSD) == [12.5, 0, nil])
    }
}
