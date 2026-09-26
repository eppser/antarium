import Foundation
import Testing
@testable import Antarium

/// `--verify-remote-discovery-reply` replays a synthetic tmux reply through
/// the real parser and reports what it produced. It is how the remote path
/// is checked without a second machine.
///
/// Nothing ran it. Not verify.sh, not the suite, and it is the only file in
/// Sources with no mutation against it that is not a SwiftUI view. A
/// documented command nobody exercises is a command nobody knows the state
/// of — and this one had a hole worth the round: every property it reports
/// is `allSatisfy`, which holds of no rows at all, so a reply that parsed
/// and yielded nothing printed four ticks and exited zero.
@Suite("The remote discovery verifier", .serialized)
struct RemoteDiscoveryEvaluationTests {

    private func reply(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Pane, process and executable, then the status line and the marker the
    /// parser looks for at the very end.
    private let complete = """
        100\t%1\t/fixture/project
        __ANTARIUM_PS__
        100 1 claude
        __ANTARIUM_EXE__
        100 /fixture/agent/claude
        __ANTARIUM_STATUS__:0:0:0
        __ANTARIUM_DONE__

        """

    @Test("A complete reply is accepted and produces a row")
    func completeReplyPasses() throws {
        let url = try reply(complete)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RemoteDiscoveryEvaluation.verify(file: url.path) == 0)
    }

    /// The hole. Accepted, parsed, and nothing in it — so `allSatisfy` held
    /// of an empty list and the command said everything was fine.
    @Test("A reply that yields no rows is not a pass")
    func emptyReplyFails() throws {
        let url = try reply("""
            __ANTARIUM_PS__
            __ANTARIUM_EXE__
            __ANTARIUM_STATUS__:0:0:0
            __ANTARIUM_DONE__

            """)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RemoteDiscoveryEvaluation.verify(file: url.path) != 0,
                "a reply with nothing in it verified four properties of nothing")
    }

    /// A reply the parser will not take is a failure whatever else is true.
    @Test("A reply with no completion marker is refused")
    func unusableReplyFails() throws {
        let url = try reply("100\t%1\t/fixture/project\n__ANTARIUM_PS__\n100 1 claude\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RemoteDiscoveryEvaluation.verify(file: url.path) != 0)
    }

    /// Reporting a host that says tmux is missing is not the same as
    /// reporting one that answered.
    @Test("A reply whose status reports trouble is refused")
    func unhealthyStatusFails() throws {
        let url = try reply(complete.replacingOccurrences(
            of: "__ANTARIUM_STATUS__:0:0:0", with: "__ANTARIUM_STATUS__:1:0:0"))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RemoteDiscoveryEvaluation.verify(file: url.path) != 0)
    }

    /// The field that says whether anything was shown, as the command
    /// prints it. The three beside it are `allSatisfy` and hold of nothing,
    /// so this is the only one a reader can rely on.
    @Test("The report says it verified nothing when there were no rows")
    func reportDistinguishesEmptiness() {
        let empty = RemoteDiscoveryEvaluation.report(accepted: true, rows: [])
        #expect(empty["verified"] as? Bool == false,
                "a reply with no rows reported itself verified")
        #expect(empty["allStatesUnknown"] as? Bool == true,
                "the vacuous properties no longer hold of nothing, so this says nothing")

        let row = AgentRow(id: "r", agentID: "claude-code", name: "p",
                           cwd: "/fixture/project", state: .unobserved)
        #expect(RemoteDiscoveryEvaluation.report(accepted: true, rows: [row])["verified"]
                as? Bool == true)
        #expect(RemoteDiscoveryEvaluation.report(accepted: false, rows: [row])["verified"]
                as? Bool == false, "a refused reply reported itself verified")
    }

    /// The state is read as a case, not as the word the row displays.
    /// Asking `label == "Unknown"` matched a cloud state whose own text is
    /// "unknown" — it capitalises to exactly that — and would have reported
    /// a false failure the moment somebody reworded the label.
    @Test("A cloud row labelled unknown is not an unobserved row")
    func cloudLabelIsNotAState() {
        let cloud = AgentRow.State.cloud("unknown")
        #expect(cloud.label == "Unknown", "the label no longer collides, so this proves nothing")
        #expect(!cloud.isUnobserved, "a cloud row was counted as unobserved")
        #expect(AgentRow.State.unobserved.isUnobserved)

        var row = AgentRow(id: "r", agentID: "a", name: "n", cwd: "/p", state: cloud)
        row.isRemote = true
        #expect(RemoteDiscoveryEvaluation.report(accepted: true, rows: [row])["allStatesUnknown"]
                as? Bool == false,
                "a reply of cloud rows reported every state unknown")
    }

    @Test("A file that is not there is a failure, not a pass")
    func missingFileFails() {
        #expect(RemoteDiscoveryEvaluation.verify(
            file: "/nonexistent/\(UUID().uuidString)") != 0)
    }
}
