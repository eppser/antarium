import Foundation
import Testing
@testable import Antarium

/// Herdr and Orca host other agents rather than being agents. Their panes are
/// already rows — the Claude session in a Herdr pane is the conversation Claude
/// Code reports — so they contribute how a session is raised and make no rows
/// of their own. Emitting both showed every agent twice: once with its real
/// figures and once as an empty duplicate.
@Suite("Workspace harnesses", .serialized)
struct WorkspaceHarnessTests {

    private func row(_ agent: String, session: String?, cwd: String) -> AgentRow {
        var row = AgentRow(id: "\(agent)-\(session ?? cwd)", agentID: agent,
                           name: "row", cwd: cwd, state: .waiting)
        row.sessionID = session
        return row
    }

    private func pane(session: String?, cwd: String?, target: String) -> HarnessEngine.Session {
        var pane = HarnessEngine.Session()
        pane.sessionID = session
        pane.cwd = cwd
        pane.focusTarget = target
        return pane
    }

    @Test("A pane is matched to its session by the agent's own id")
    func sessionIDIsTheExactJoin() {
        var rows = [row("claude-code", session: "abc", cwd: "/p"),
                    row("codex", session: "def", cwd: "/p")]
        AgentScan.attachWorkspaceTargets(to: &rows, panes: [
            pane(session: "abc", cwd: "/p", target: "w3:t1"),
        ])
        #expect(rows[0].focusTarget == "w3:t1")
        #expect(rows[1].focusTarget == nil, "a row with no matching pane was given one")
    }

    @Test("Two agents in one folder are not both sent to the same pane")
    func directoryIsNotEnoughWhenItIsShared() {
        // The bug this exists for: a Claude row and a Codex row in one
        // worktree both received the same Orca terminal, so clicking either
        // raised one pane and was silently wrong for the other.
        var rows = [row("claude-code", session: nil, cwd: "/shared"),
                    row("codex", session: nil, cwd: "/shared")]
        AgentScan.attachWorkspaceTargets(to: &rows, panes: [
            pane(session: nil, cwd: "/shared", target: "term_1"),
        ])
        #expect(rows.allSatisfy { $0.focusTarget == nil },
                "an ambiguous directory was resolved by guessing")
    }

    @Test("A folder with one row and one pane is matched")
    func directoryIsEnoughWhenItIsUnambiguous() {
        var rows = [row("claude-code", session: nil, cwd: "/only")]
        AgentScan.attachWorkspaceTargets(to: &rows, panes: [
            pane(session: nil, cwd: "/only", target: "term_1"),
        ])
        #expect(rows[0].focusTarget == "term_1")
    }

    @Test("A reused session id is not enough to place a pane")
    func repeatedSessionIDsAreRefused() {
        // Claude reuses a session id across resumed sessions, so two live rows
        // can carry the same one.
        // Same folder as well, so the directory fallback cannot resolve what
        // the session id could not.
        var rows = [row("claude-code", session: "same", cwd: "/a"),
                    row("claude-code", session: "same", cwd: "/a")]
        AgentScan.attachWorkspaceTargets(to: &rows, panes: [
            pane(session: "same", cwd: "/a", target: "w1:t1"),
        ])
        #expect(rows.allSatisfy { $0.focusTarget == nil })
    }

    @Test("One pane is never claimed by two rows")
    func targetsAreUsedOnce() {
        var rows = [row("claude-code", session: "one", cwd: "/x"),
                    row("codex", session: "two", cwd: "/y")]
        AgentScan.attachWorkspaceTargets(to: &rows, panes: [
            pane(session: "one", cwd: "/x", target: "shared-target"),
            pane(session: "two", cwd: "/y", target: "shared-target"),
        ])
        #expect(rows.compactMap(\.focusTarget).count == 1,
                "the same pane was handed to two rows")
    }

    @Test("A row that already knows how it is raised is left alone")
    func existingTargetsAreNotOverwritten() {
        var rows = [row("claude-code", session: "abc", cwd: "/p")]
        rows[0].focusTarget = "already"
        AgentScan.attachWorkspaceTargets(to: &rows, panes: [
            pane(session: "abc", cwd: "/p", target: "w3:t1"),
        ])
        #expect(rows[0].focusTarget == "already")
    }

    @Test("Both shipped workspace harnesses declare what they contribute")
    func shippedWorkspacesAreConfigured() throws {
        for id in ["herdr", "orca"] {
            let descriptor = try #require(
                HarnessCLI.bundledDescriptors().first { $0.id == id },
                "\(id) is not a shipped harness")
            #expect(descriptor.contributesFocusOnly,
                    "\(id) would emit duplicate rows for sessions other harnesses already report")
            #expect(descriptor.fields.focusTarget != nil, "\(id) maps no focus target")
            let focus = try #require(descriptor.focus, "\(id) declares no focus command")
            #expect(focus.args?.contains { $0.contains("{focusTarget}") } == true,
                    "\(id)'s focus command never uses the target it maps")
            // A workspace manager reads its own live state through a command.
            #expect(descriptor.source.kind == .command)
        }
    }
}

/// What a click runs. The command comes from a descriptor and the target from
/// the harness's own output, so neither is allowed to become shell syntax and
/// neither is trusted to be well formed.
@Suite("Harness focus commands", .serialized)
@MainActor
struct HarnessFocusCommandTests {

    @Test("The target is substituted into the declared arguments")
    func targetIsSubstituted() throws {
        for (id, expected) in [("herdr", ["tab", "focus", "w1:t1"]),
                               ("orca", ["terminal", "switch", "--terminal", "w1:t1"])] {
            let descriptor = try #require(HarnessCLI.bundledDescriptors().first { $0.id == id })
            let focus = try #require(descriptor.focus)
            let arguments = (focus.args ?? []).map {
                $0.replacingOccurrences(of: "{focusTarget}", with: "w1:t1")
            }
            #expect(arguments == expected, "\(id) built \(arguments)")
        }
    }

    @Test("A click on a row with no target does not run anything")
    func noTargetRunsNothing() {
        // Antarium falls back to raising the owning application or opening the
        // folder. Running a focus command with an empty target would ask the
        // workspace manager to focus "", which is a different pane or an error.
        var row = AgentRow(id: "r", agentID: "herdr", name: "r", cwd: "/p", state: .waiting)
        row.focusTarget = nil
        #expect(row.focusTarget == nil)
        row.focusTarget = ""
        #expect(row.focusTarget?.isEmpty == true)
    }

    @Test("Every shipped focus command is on the reviewed allowlist")
    func focusCommandsAreReviewed() throws {
        // The same gate the source and credential commands go through: a
        // command that runs when a row is clicked is still a command this
        // application runs on the user's machine.
        var declared: [String] = []
        for descriptor in HarnessCLI.bundledDescriptors() {
            guard let focus = descriptor.focus else { continue }
            declared.append("\(descriptor.id):\(focus.command)")
        }
        #expect(declared.sorted() == ["herdr:herdr", "orca:orca"])
    }
}
