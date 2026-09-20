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
        // Calls the production builder. An earlier version did the
        // substitution itself, so removing it from the app changed nothing
        // and the test stayed green.
        for (id, expected) in [("herdr", ["tab", "focus", "w1:t1"]),
                               ("orca", ["terminal", "switch", "--terminal", "w1:t1"])] {
            let descriptor = try #require(HarnessCLI.bundledDescriptors().first { $0.id == id })
            let focus = try #require(descriptor.focus)
            let arguments = Focus.focusArguments(focus, target: "w1:t1")
            #expect(arguments == expected, "\(id) built \(arguments ?? [])")
        }
    }

    @Test("A target that cannot mean a pane runs nothing")
    func unusableTargetsAreRefused() throws {
        let descriptor = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "herdr" })
        let focus = try #require(descriptor.focus)
        // Empty would ask the manager to focus "", which is a different pane
        // or an error — either way not the row that was clicked.
        #expect(Focus.focusArguments(focus, target: "") == nil)
        // A NUL truncates a C string, so the argument the manager receives
        // would not be the one that was built.
        #expect(Focus.focusArguments(focus, target: "w1\u{0}:t1") == nil)
        // And a target no pane id could be is refused rather than passed on.
        #expect(Focus.focusArguments(focus, target: String(repeating: "x", count: 600)) == nil)
        #expect(Focus.focusArguments(focus, target: "w1:t1") != nil)
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

/// A workspace manager is not an agent and not a menu bar item, so it appears
/// nowhere in the lists that drive either. Its one visible effect — a click
/// opening the right pane — had no explanation until first run mentioned it.
@Suite("Workspace detection", .serialized)
struct WorkspaceDetectionTests {

    private let all = HarnessCLI.bundledDescriptors()
    private func descriptors() -> [HarnessDescriptor] { all }

    @Test("Presence is whether the command it is read through resolves")
    func presenceFollowsTheCommand() {
        let found = Onboarding.workspaces(all) { _ in "/opt/example/bin/tool" }
        #expect(found.count >= 2, "no workspace harness is shipped")
        // Computed outside the macro: allSatisfy is rethrows, and #expect
        // cannot prove the closure does not throw.
        let allPresent = found.filter(\.found).count == found.count
        let allExplained = found.filter { $0.detail == "routes clicks to the right pane" }.count
        #expect(allPresent)
        #expect(allExplained == found.count)

        let absent = Onboarding.workspaces(all) { _ in nil }
        let nonePresent = absent.filter(\.found).isEmpty
        let allAbsentDetail = absent.filter { $0.detail == "not on this Mac" }.count
        #expect(nonePresent)
        #expect(allAbsentDetail == absent.count)
    }

    @Test("They are not offered as agents or as menu bar providers")
    func workspacesAreNeitherAgentsNorProviders() {
        // Listing them under "agents found" would claim they are agents; as a
        // provider they would be a bar item with no quota to show.
        let ids = Set(Onboarding.workspaces(all).map(\.id))
        #expect(ids.contains("herdr") && ids.contains("orca"))
        let agentIDs = Set(Onboarding.harnesses(all).map(\.id))
        let providerIDs = Set(ProviderRegistry.providers(from: all).map(\.id))
        #expect(agentIDs.isDisjoint(with: ids))
        #expect(providerIDs.isDisjoint(with: ids))
    }

    @Test("A workspace manager declares no quota and no session store")
    func workspacesCarryNeitherQuotaNorSessions() {
        var seen = 0
        for descriptor in all where descriptor.contributesFocusOnly {
            seen += 1
            #expect(descriptor.quota == nil,
                    "\(descriptor.id) would become a menu bar item")
            #expect(descriptor.source.path.isEmpty,
                    "\(descriptor.id) would be listed as an installed agent")
        }
        #expect(seen >= 2, "no workspace harness was examined")
    }
    @Test("A workspace harness contributes no rows of its own")
    func workspacesEmitNoRows() throws {
        // The duplicate-row bug: before `contributes` existed, every agent
        // appeared twice — once from its own harness with real figures, once
        // from the workspace manager as an empty row. Checked through the
        // scan's own row builder rather than by reading the descriptor.
        let workspaces = HarnessCLI.bundledDescriptors().filter(\.contributesFocusOnly)
        #expect(workspaces.count >= 2, "no workspace harness is shipped")
        for descriptor in workspaces {
            #expect(AgentScan.rows(for: descriptor, processes: [:]).isEmpty,
                    "\(descriptor.id) produced rows that duplicate other harnesses'")
        }
        // Not vacuous: the same entry point, the same command source, and the
        // only difference is the declaration. Herdr and Orca are the only
        // command harnesses shipped, so the contrast has to be built.
        func descriptor(contributingFocus: Bool) throws -> HarnessDescriptor {
            var document: [String: Any] = [
                "formatVersion": 1, "id": "synthetic", "name": "Synthetic",
                "process": [:],
                "source": ["kind": "command", "path": "",
                           "command": "/bin/echo",
                           "args": ["[{\"cwd\":\"/projects/sample\"}]"]],
                "map": ["cwd": "cwd"],
            ]
            if contributingFocus { document["contributes"] = "focus" }
            return try HarnessDocument.decode(
                JSONSerialization.data(withJSONObject: document)).descriptor
        }
        HarnessEngine.resetCaches(includingParsedFiles: true)
        let emitting = AgentScan.rows(for: try descriptor(contributingFocus: false),
                                      processes: [:])
        #expect(emitting.count == 1, "the control case produced no rows, so the check is empty")
        HarnessEngine.resetCaches(includingParsedFiles: true)
        #expect(AgentScan.rows(for: try descriptor(contributingFocus: true),
                               processes: [:]).isEmpty)
    }
}
