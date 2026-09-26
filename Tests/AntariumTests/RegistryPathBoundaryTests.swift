import Foundation
import Testing
@testable import Antarium

@Suite("Registry transcript path boundaries")
struct RegistryPathBoundaryTests {
    private func fixture(_ body:(URL,URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-fixture-\(UUID())")
        let project = root.appendingPathComponent("-fixture-project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try body(root,project)
    }
    @Test("A session identifier cannot traverse out of its declared project directory")
    func traversal() throws {
        try fixture { root, _ in
            try Data("{}\n".utf8).write(to:root.appendingPathComponent("outside.jsonl"))
            #expect(AgentScan.transcriptURL(cwd:"/fixture/project",sessionID:"../outside",root:root.path) == nil)
        }
    }
    @Test("Linked transcripts are unavailable instead of binding outside the trace source")
    func symlink() throws {
        try fixture { root, project in
            let target = root.appendingPathComponent("outside.jsonl")
            try Data("{}\n".utf8).write(to:target)
            try FileManager.default.createSymbolicLink(at:project.appendingPathComponent("session.jsonl"),withDestinationURL:target)
            #expect(AgentScan.transcriptURL(cwd:"/fixture/project",sessionID:"session",root:root.path) == nil)
        }
    }
    @Test("Exact and resumed-session matches still resolve regular bounded sources")
    func valid() throws {
        try fixture { root, project in
            let file = project.appendingPathComponent("first.jsonl")
            try Data(#"{"sessionId":"resumed"}"#.utf8).write(to:file)
            #expect(AgentScan.transcriptURL(cwd:"/fixture/project",sessionID:"first",root:root.path) == file)
            #expect(AgentScan.transcriptURL(cwd:"/fixture/project",sessionID:"resumed",root:root.path)?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        }
    }
    @Test("A quoted example of another session ID is not a resumed-session binding")
    func embeddedID() throws {
        try fixture { root, project in
            let object:[String:Any] = ["sessionId":"actual","message":["sessionId":"unrelated"]]
            try JSONSerialization.data(withJSONObject:object,options:.sortedKeys).write(to:project.appendingPathComponent("first.jsonl"))
            #expect(AgentScan.transcriptURL(cwd:"/fixture/project",sessionID:"unrelated",root:root.path) == nil)
        }
    }
}

/// Finding the transcript a resumed session is actually writing to. The
/// boundaries — traversal, control characters, links — are covered above;
/// which file it picks when several could match was not, and picking the
/// wrong one puts another session's figures on the row.
@Suite("Resumed transcript resolution", .serialized)
struct ResumedTranscriptTests {

    private let cwd = "/synthetic/project"

    /// Files are written oldest first and stamped explicitly, so the ordering
    /// under test is the one being asserted rather than whatever the
    /// filesystem happened to record.
    private func project(_ files: [(name: String, sessionID: String?, age: TimeInterval)])
        throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            let url = dir.appendingPathComponent(file.name)
            let line = file.sessionID.map { #"{"sessionId":"\#($0)","x":1}"# + "\n" } ?? "{}\n"
            try Data(line.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-file.age)], ofItemAtPath: url.path)
        }
        return root
    }

    @Test("A transcript named for the session is used directly")
    func exactMatch() throws {
        let root = try project([("wanted.jsonl", nil, 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = AgentScan.transcriptURL(cwd: cwd, sessionID: "wanted", root: root.path)
        #expect(found?.lastPathComponent == "wanted.jsonl")
    }

    /// Claude keeps the original id as the filename across a resume, so the
    /// id has to be found inside. Several files can carry it, and the one
    /// being written to now is the newest — an older one holds the figures
    /// from a session that has already finished.
    @Test("When several transcripts name the session, the newest wins")
    func newestWins() throws {
        let root = try project([
            ("old.jsonl", "shared", 3_600),
            ("newer.jsonl", "shared", 60),
            ("oldest.jsonl", "shared", 86_400),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = AgentScan.transcriptURL(cwd: cwd, sessionID: "shared", root: root.path)
        #expect(found?.lastPathComponent == "newer.jsonl")
    }

    /// The search reads and parses each candidate, so it stops after the few
    /// newest. A project with a long history must not cost a scan.
    @Test("Only the newest few transcripts are searched")
    func searchIsBounded() throws {
        var files: [(String, String?, TimeInterval)] = []
        for i in 0..<20 { files.append(("decoy-\(i).jsonl", "other", TimeInterval(i * 60))) }
        // The one that names the session is older than the eight newest.
        files.append(("wanted.jsonl", "shared", 86_400))
        let root = try project(files.map { (name: $0.0, sessionID: $0.1, age: $0.2) })
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentScan.transcriptURL(cwd: cwd, sessionID: "shared", root: root.path) == nil,
                "the search went further back than its bound")
    }

    @Test("A file that is not a transcript is not searched")
    func onlyTranscripts() throws {
        let root = try project([("notes.txt", "shared", 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentScan.transcriptURL(cwd: cwd, sessionID: "shared", root: root.path) == nil)
    }

    @Test("A project with no matching transcript resolves to nothing")
    func noMatch() throws {
        let root = try project([("other.jsonl", "different", 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentScan.transcriptURL(cwd: cwd, sessionID: "shared", root: root.path) == nil)
    }
}

/// The order the dashboard puts its rows in.
///
/// Swift's sort is not stable, so an order that stops at its first key lets
/// equal rows swap on every scan — the list reshuffles under the pointer
/// while nothing about the machine has changed. Four of the five orders
/// already fell through to status and recency for this reason; the fifth did
/// not, and that is the one most machines are in a position to notice.
@Suite("Every dashboard order is stable between scans")
struct AgentSortStabilityTests {

    private func row(_ id: String, name: String = "project", agent: String = "claude-code",
                     host: String? = nil, cost: Double? = nil,
                     state: AgentRow.State = .waiting,
                     activity: Date? = nil) -> AgentRow {
        AgentRow(id: id, agentID: agent, name: name, cwd: "/synthetic/\(name)",
                 state: state, lastActivity: activity, costUSD: cost, hostApp: host)
    }

    /// Rows that tie on everything the order looks at. Shuffled repeatedly
    /// because the failure is an order that depends on the input's order, and
    /// one arrangement agreeing with itself proves nothing.
    private func isStable(_ rows: [AgentRow], _ order: AgentSort) -> Bool {
        let wanted = AgentScan.sorted(rows, by: order).map(\.id)
        for _ in 0..<25 where AgentScan.sorted(rows.shuffled(), by: order).map(\.id) != wanted {
            return false
        }
        return true
    }

    /// The one that was wrong. Only some harnesses report a cost, so a
    /// machine where most rows carry none — which is most machines — put
    /// every costless row at the same value with nothing to separate them.
    @Test("Sorting by spend does not reshuffle rows that report no cost")
    func spendWithoutCosts() {
        let rows = (1...6).map { row("row-\($0)", name: "p\($0)") }
        #expect(isStable(rows, .spend),
                "rows with no cost came back in a different order")
    }

    @Test("Sorting by spend still puts the biggest spender first")
    func spendStillOrders() {
        let rows = [row("a", cost: 1.5), row("b", cost: 12), row("c", cost: nil), row("d", cost: 0)]
        #expect(AgentScan.sorted(rows, by: .spend).map(\.id) == ["b", "a", "d", "c"],
                "a reported zero and no report at all were treated as the same thing")
    }

    /// Every order, against rows that tie as hard as they can.
    @Test("Rows that tie on everything visible still come back in one order",
          arguments: AgentSort.allCases)
    func everyOrderIsTotal(order: AgentSort) {
        let same = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (1...6).map {
            row("row-\($0)", name: "same", agent: "claude-code", host: "tmux",
                cost: nil, state: .waiting, activity: same)
        }
        #expect(isStable(rows, order),
                Comment(rawValue: "\(order) reordered rows that differ only by id"))
    }

    /// And the orders still order, or the tie-break above would be satisfied
    /// by ignoring the key entirely.
    @Test("Each order still sorts by the thing it names")
    func ordersStillOrder() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_009_999)
        #expect(AgentScan.sorted([row("b", name: "zeta"), row("a", name: "alpha")],
                                 by: .name).map(\.id) == ["a", "b"])
        #expect(AgentScan.sorted([row("b", agent: "zai"), row("a", agent: "codex")],
                                 by: .harness).map(\.id) == ["a", "b"])
        #expect(AgentScan.sorted([row("b", host: "Warp"), row("a", host: "Ghostty")],
                                 by: .host).map(\.id) == ["a", "b"])
        #expect(AgentScan.sorted([row("b", activity: older), row("a", activity: newer)],
                                 by: .activity).map(\.id) == ["a", "b"])
    }
}
