import Foundation
import Testing
@testable import Antarium

/// What a click on a row tries, and in what order. The order is the whole
/// thing: a harness that owns its own windows — herdr, orca — knows which
/// pane of which tab a session is, and raising the application instead lands
/// on whatever it had open last. That failure looks like success from the
/// outside, which is why it needs a test rather than a look.
@Suite("Clicking a row routes to the right window")
struct ClickRoutingTests {

    private func row(agent: String = "claude-code", pid: Int32? = 42,
                     cwd: String = "/tmp/project",
                     tmux: String? = nil, focusTarget: String? = nil,
                     remote: Bool = false,
                     issue: String? = nil) -> AgentRow {
        var row = AgentRow(id: "r", agentID: agent, name: "s", cwd: cwd, state: .waiting)
        row.pid = pid
        row.tmuxTarget = tmux
        row.focusTarget = focusTarget
        row.isRemote = remote
        row.localObservationIssue = issue
        return row
    }

    private let noFocus: (String) -> Bool = { _ in false }
    private let hasFocus: (String) -> Bool = { _ in true }

    @Test("A workspace manager is asked before the application is raised")
    func harnessComesFirst() {
        let steps = Focus.plan(row(agent: "orca", pid: 42, tmux: "s:1.0",
                                   focusTarget: "w3:t2"),
                               descriptorHasFocus: hasFocus)
        #expect(steps.first == .harness(id: "orca", target: "w3:t2"),
                "raising the app first lands on whatever it had open last")
        // And the rest remain as fallbacks, in their own order.
        #expect(steps == [.harness(id: "orca", target: "w3:t2"),
                          .tmux("s:1.0"), .app(pid: 42), .folder("/tmp/project")])
    }

    @Test("A harness with no focus command is not asked")
    func noFocusCommandNoStep() {
        let steps = Focus.plan(row(agent: "orca", focusTarget: "w3:t2"),
                               descriptorHasFocus: noFocus)
        #expect(!steps.contains { if case .harness = $0 { return true }; return false })
    }

    /// A harness that declares a focus command but has no target for this row
    /// would be asked to focus nothing, which is either a different pane or an
    /// error — and either way not the row that was clicked.
    @Test("A harness with no usable target for this row is not asked", arguments: [nil, ""])
    func missingTargetIsNotAsked(_ target: String?) {
        let steps = Focus.plan(row(agent: "orca", focusTarget: target),
                               descriptorHasFocus: hasFocus)
        #expect(!steps.contains { if case .harness = $0 { return true }; return false })
        #expect(steps.first == .app(pid: 42), "it falls through to the next thing")
    }

    @Test("tmux is preferred to raising the application")
    func tmuxBeforeApp() {
        let steps = Focus.plan(row(tmux: "session:@1.%2"), descriptorHasFocus: noFocus)
        #expect(steps == [.tmux("session:@1.%2"), .app(pid: 42), .folder("/tmp/project")])
    }

    @Test("With no process and no pane, the folder is the last thing left")
    func folderIsTheFallback() {
        let steps = Focus.plan(row(pid: nil), descriptorHasFocus: noFocus)
        #expect(steps == [.folder("/tmp/project")])
    }

    @Test("A row with nothing to raise plans nothing")
    func nothingToDo() {
        let steps = Focus.plan(row(pid: nil, cwd: ""), descriptorHasFocus: noFocus)
        #expect(steps.isEmpty)
    }

    @Test("A remote row is never routed locally")
    func remoteRowsAreNotLocal() {
        let steps = Focus.plan(row(tmux: "s:1.0", focusTarget: "w3:t2", remote: true),
                               descriptorHasFocus: hasFocus)
        #expect(steps.isEmpty, "a click would have raised a local window for a remote session")
    }

    /// A row whose local observation failed knows nothing reliable about the
    /// process behind it, so its pid may belong to something else entirely.
    @Test("A row we could not observe locally is not routed either")
    func unobservedRowsAreNotRouted() {
        let steps = Focus.plan(row(issue: "Process list unavailable."),
                               descriptorHasFocus: hasFocus)
        #expect(steps.isEmpty)
    }

    /// The shipped workspace harnesses are the reason the first step exists.
    @Test("Every shipped harness that owns its windows declares how to raise one")
    func shippedWorkspaceHarnessesCanBeRaised() throws {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        var checked = 0
        for url in urls {
            let descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            guard descriptor.contributes == .focus else { continue }
            let focus = try #require(descriptor.focus,
                                     Comment(rawValue: "\(descriptor.id) manages windows "
                                             + "but declares no way to raise one"))
            #expect(!focus.command.isEmpty)
            // The substitution has to actually consume the target, or every
            // row of this harness raises the same window.
            let args = try #require(Focus.focusArguments(focus, target: "synthetic-target"))
            #expect(args.contains { $0.contains("synthetic-target") },
                    Comment(rawValue: "\(descriptor.id) ignores the target it is given"))
            checked += 1
        }
        #expect(checked >= 2, "herdr and orca should both be covered here")
    }
}
