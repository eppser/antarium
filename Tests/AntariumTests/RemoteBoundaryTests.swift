import Foundation
import Testing
@testable import Antarium

@Suite("SSH discovery input and result boundaries")
struct RemoteBoundaryTests {
    @Test("Host destinations reject controls and oversized values", arguments:[
        "fixture\u{0}ignored", "fixture\u{1}host", "fixture\u{7}host", "fixture\u{7f}host",
        String(repeating:"a",count:1_025)
    ])
    func hostBoundary(_ host: String) { #expect(!RemoteTmux.isSafeHost(host)) }

    @Test("SSH diagnostics explain a failure without copying remote text")
    func diagnosticPrivacy() {
        let inputs = [
            "ssh: fixture-user@fixture-host: Permission denied; API_KEY=fixture-secret",
            "ssh: Could not resolve hostname fixture-secret: nodename not found",
            "ssh: connect to host fixture-secret port 22: Connection refused",
            "Host key verification failed for /fixture/fixture-secret",
            "Connection timed out: fixture-secret",
            "No route to host fixture-secret"
        ]
        for input in inputs {
            let reason = RemoteTmux.sshReason(input)
            #expect(reason != nil)
            #expect(reason?.contains("fixture") == false)
        }
    }
    @Test("Cancellation cannot turn partial discovery output into a successful scan")
    func cancelledReply() {
        let answer = Shell.Result(stdout:RemoteTmux.psSeparator + "\n",stderr:"",exitCode:0,
            timedOut:false,launchError:nil,cancelled:true)
        #expect(!RemoteTmux.usable(answer))
    }
}

/// Building rows from a reply. The transfer limits are covered elsewhere;
/// these are the rules the parse itself follows, on input from a machine this
/// one does not control.
@Suite("Remote rows are built predictably from untrusted output")
struct RemoteRowConstructionTests {

    private func descriptors() throws -> [HarnessDescriptor] {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        return try urls.map { try HarnessDocument.decode(Data(contentsOf: $0)).descriptor }
    }

    /// panes, then ps (`pid ppid comm args`), then pid-to-executable.
    private func reply(panes: [(pid: Int, target: String, cwd: String)],
                       ps: [(pid: Int, ppid: Int, comm: String, args: String)],
                       exe: [(pid: Int, path: String)]) -> String {
        var out = panes.map { "\($0.pid)\t\($0.target)\t\($0.cwd)" }.joined(separator: "\n")
        out += "\n" + RemoteTmux.psSeparator + "\n"
        out += ps.map { "\($0.pid) \($0.ppid) \($0.comm) \($0.args)" }.joined(separator: "\n")
        out += "\n" + RemoteTmux.exeSeparator + "\n"
        out += exe.map { "\($0.pid) \($0.path)" }.joined(separator: "\n")
        return out + "\n"
    }

    private let claude = "/opt/claude/versions/2.1.0"

    @Test("An agent under a pane becomes a row for that pane")
    func ordinaryRow() throws {
        let loaded = try descriptors()
        let rows = RemoteTmux.parse(reply(
            panes: [(100, "session:@1.%1", "/synthetic/project")],
            ps: [(100, 1, "node", claude)],
            exe: [(100, claude)]), host: "example.invalid") { loaded }
        let row = try #require(rows.first)
        #expect(row.cwd == "/synthetic/project")
        #expect(row.agentID == "claude-code")
    }

    /// The agent is often a grandchild of the pane — a shell, or `npx`, sits
    /// between — so the walk climbs. It stops after eight levels, because the
    /// parent table comes from another machine and a cycle in it would
    /// otherwise never end.
    @Test("An agent several levels below its pane is still attached")
    func walkClimbs() throws {
        let loaded = try descriptors()
        let rows = RemoteTmux.parse(reply(
            panes: [(100, "session:@1.%1", "/synthetic/project")],
            ps: [(100, 1, "zsh", "-zsh"), (101, 100, "sh", "sh"), (102, 101, "node", claude)],
            exe: [(102, claude)]), host: "example.invalid") { loaded }
        #expect(rows.count == 1)
        #expect(rows.first?.cwd == "/synthetic/project")
    }

    /// A parent chain that loops. Unbounded, the walk never returns and the
    /// scan never finishes — a remote machine could hang the menu bar by
    /// reporting it.
    @Test("A cycle in the reported parent chain terminates", .timeLimit(.minutes(1)))
    func cyclicParents() throws {
        let loaded = try descriptors()
        let rows = RemoteTmux.parse(reply(
            panes: [(100, "session:@1.%1", "/synthetic/project")],
            ps: [(200, 201, "node", claude), (201, 200, "sh", "sh")],
            exe: [(200, claude)]), host: "example.invalid") { loaded }
        // No pane is reachable from the cycle, so no row — the point is that
        // the answer arrives at all.
        #expect(rows.isEmpty)
    }

    /// Rows must not shuffle between scans. The order is the pid order, not
    /// whatever the dictionary yields.
    @Test("Rows come back in a stable order")
    func stableOrder() throws {
        let loaded = try descriptors()
        let text = reply(
            panes: [(300, "s:@1.%1", "/synthetic/c"), (100, "s:@1.%2", "/synthetic/a"),
                    (200, "s:@1.%3", "/synthetic/b")],
            ps: [(300, 1, "node", claude), (100, 1, "node", claude), (200, 1, "node", claude)],
            exe: [(300, claude), (100, claude), (200, claude)])
        let first = RemoteTmux.parse(text, host: "example.invalid") { loaded }
        #expect(first.map(\.cwd) == ["/synthetic/a", "/synthetic/b", "/synthetic/c"])
        let again = RemoteTmux.parse(text, host: "example.invalid") { loaded }
        #expect(again.map(\.cwd) == first.map(\.cwd))
    }

    @Test("A process no descriptor claims is not a row")
    func unclaimedProcess() throws {
        let loaded = try descriptors()
        let rows = RemoteTmux.parse(reply(
            panes: [(100, "s:@1.%1", "/synthetic/project")],
            ps: [(100, 1, "vim", "/usr/bin/vim")],
            exe: [(100, "/usr/bin/vim")]), host: "example.invalid") { loaded }
        #expect(rows.isEmpty)
    }
}
