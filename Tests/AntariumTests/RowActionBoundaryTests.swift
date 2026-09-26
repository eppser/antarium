import Foundation
import Testing
@testable import Antarium

/// What a row's menu is allowed to do with it.
///
/// The rule that a remote row must not drive this Mac lived in
/// `Focus.canRevealLocally`, was asserted by the click-routing tests, and was
/// checked by the remote discovery evaluation. The row's own menu never asked
/// it. "Open Directory", "Open in Terminal" and "Copy Path" took `row.cwd`
/// straight to `NSWorkspace` and the pasteboard.
///
/// A remote row's `cwd` is the other machine's. On two Macs with the same
/// username and a checkout of the same name that path exists on both, so the
/// user was shown this machine's files while believing they were the
/// session's — worse than an error, because nothing looks wrong.
@Suite("A row only offers what it can actually do")
struct RowActionBoundaryTests {

    private func row(remote: Bool = false, cwd: String = "/synthetic/project",
                     tmux: String? = nil, issue: String? = nil,
                     host: String? = nil) -> AgentRow {
        var row = AgentRow(id: "r", agentID: "claude-code", name: "project",
                           cwd: cwd, state: .working, lastActivity: nil,
                           costUSD: nil, hostApp: remote ? RemoteTmux.tag : "Terminal")
        row.isRemote = remote
        row.remoteHost = remote ? (host ?? "build-box") : nil
        row.pid = 4321
        row.tmuxTarget = tmux
        row.localObservationIssue = issue
        return row
    }

    /// The defect, stated as the three actions that touched this machine.
    @Test("A remote row offers nothing that acts on this Mac")
    func remoteRowsCannotActLocally() {
        let allowed = Focus.actions(for: row(remote: true))
        #expect(!allowed.contains(.openDirectory),
                "a remote row offered to open this machine's copy of its path")
        #expect(!allowed.contains(.openInTerminal),
                "a remote row offered a local terminal at another machine's path")
        #expect(!allowed.contains(.goToWindow),
                "a remote row offered a click that reveal() refuses")
    }

    /// And the local row still offers all of them, or the rule above would be
    /// satisfied by offering nothing to anyone.
    @Test("A local row offers the lot")
    func localRowsOfferEverything() {
        let allowed = Focus.actions(for: row())
        #expect(allowed.contains(.openDirectory))
        #expect(allowed.contains(.openInTerminal))
        #expect(allowed.contains(.goToWindow))
        #expect(allowed.contains(.copyPath))
    }

    /// Copying stays available because a path is useful either way — but a
    /// remote one has to say whose it is.
    @Test("A remote path is copied with its host, a local one without")
    func copiedPathNamesItsMachine() throws {
        let remote = try #require(Focus.pathToCopy(for: row(remote: true, host: "build-box")))
        #expect(remote == "build-box:/synthetic/project",
                Comment(rawValue: "copied \(remote)"))
        #expect(Focus.pathToCopy(for: row()) == "/synthetic/project")
        // Nothing to copy is nothing to offer.
        #expect(Focus.pathToCopy(for: row(cwd: "")) == nil)
        #expect(!Focus.actions(for: row(cwd: "")).contains(.copyPath))
    }

    /// A local tmux session can be attached to; a remote one cannot, because
    /// the attach runs here and would join a same-named session on this Mac.
    @Test("Attaching is offered only for a session on this machine")
    func attachIsLocalOnly() {
        #expect(Focus.actions(for: row(tmux: "work:1.0")).contains(.attachTmux))
        #expect(!Focus.actions(for: row(remote: true, tmux: "work:1.0")).contains(.attachTmux))
        #expect(!Focus.actions(for: row()).contains(.attachTmux),
                "a row with no tmux target was offered an attach")
    }

    /// A local row whose process could not be inspected cannot be revealed
    /// either — the same rule `canRevealLocally` already enforced, now applied
    /// where the menu is built.
    @Test("An uninspectable local row is not offered a reveal")
    func uninspectableRowsCannotReveal() {
        let allowed = Focus.actions(for: row(issue: "This process could not be inspected."))
        #expect(!allowed.contains(.goToWindow))
        // Its directory is still this machine's, so that much still works.
        #expect(allowed.contains(.openDirectory))
    }

    /// The actions refuse for themselves, not only because a button was
    /// hidden. A hidden button is a rule somebody can forget to apply; a
    /// refusal is one they cannot.
    @Test("A remote row's local actions refuse to run")
    func actionsRefuseThemselves() {
        var opened: [URL] = []
        var copied: [String] = []
        let remote = row(remote: true)
        #expect(Focus.openDirectory(remote) { opened.append($0) } == false)
        #expect(Focus.openInTerminal(remote) { opened.append($0) } == false)
        #expect(opened.isEmpty,
                Comment(rawValue: "a remote row reached this machine: \(opened)"))
        // Copying is permitted, and carries the host.
        #expect(Focus.copyPath(remote) { copied.append($0) })
        #expect(copied == ["build-box:/synthetic/project"],
                Comment(rawValue: "copied \(copied)"))
    }

    /// And a local row's actions do run, or refusing everything would satisfy
    /// the assertion above.
    @Test("A local row's actions run")
    func localActionsRun() {
        var opened: [URL] = []
        var copied: [String] = []
        let local = row()
        #expect(Focus.openDirectory(local) { opened.append($0) })
        #expect(Focus.openInTerminal(local) { opened.append($0) })
        #expect(opened.map(\.path) == ["/synthetic/project", "/synthetic/project"])
        #expect(Focus.copyPath(local) { copied.append($0) })
        #expect(copied == ["/synthetic/project"])
    }

    /// A row with no directory has nothing to open or copy.
    @Test("A row with no directory does nothing")
    func emptyDirectoryDoesNothing() {
        var touched = false
        let empty = row(cwd: "")
        #expect(Focus.openDirectory(empty) { _ in touched = true } == false)
        #expect(Focus.openInTerminal(empty) { _ in touched = true } == false)
        #expect(Focus.copyPath(empty) { _ in touched = true } == false)
        #expect(!touched)
    }

    /// Every action is decided for every shape of row, so a new action cannot
    /// be added without this suite having an opinion about it.
    @Test("Every action is accounted for", arguments: Focus.Action.allCases)
    func everyActionIsDecided(action: Focus.Action) {
        let shapes = [row(), row(remote: true), row(tmux: "a:1.0"),
                      row(remote: true, tmux: "a:1.0"), row(cwd: ""),
                      row(issue: "unknown")]
        let decided = shapes.map { Focus.actions(for: $0).contains(action) }
        #expect(decided.contains(true),
                Comment(rawValue: "\(action) is permitted for no row at all"))
        #expect(decided.contains(false),
                Comment(rawValue: "\(action) is permitted for every row, so nothing gates it"))
    }
}
