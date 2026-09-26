import Foundation
import Testing
@testable import Antarium

/// A reply from another machine is untrusted input in the same way an HTTP
/// response is. The transfer is bounded — eight megabytes, and a truncated
/// reply refuses to update anything rather than parsing half of it — but what
/// gets built from a whole reply was not, and eight megabytes of pane lines is
/// tens of thousands of rows.
@Suite("A remote host cannot fill the dashboard")
struct RemoteRowBoundsTests {

    /// The shape RemoteTmux.parse expects: panes, then ps, then executables.
    private func reply(panes: Int) -> String {
        var out = ""
        for i in 0..<panes {
            let pid = 1000 + i
            out += "\(pid)\tsession:@\(i).%\(i)\t/tmp/project-\(i)\n"
        }
        out += RemoteTmux.psSeparator + "\n"
        for i in 0..<panes {
            let pid = 1000 + i
            out += "\(pid) 1 node /opt/claude/versions/2.1.0\n"
        }
        out += RemoteTmux.exeSeparator + "\n"
        for i in 0..<panes {
            out += "\(1000 + i) /opt/claude/versions/2.1.0\n"
        }
        return out
    }

    private func descriptors() throws -> [HarnessDescriptor] {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        return try urls.map { try HarnessDocument.decode(Data(contentsOf: $0)).descriptor }
    }

    @Test("A reply describing thousands of panes yields a bounded number of rows")
    func floodIsBounded() throws {
        let loaded = try descriptors()
        let rows = RemoteTmux.parse(reply(panes: 5_000), host: "example.invalid") { loaded }
        #expect(rows.count <= RemoteTmux.maxRows,
                "a remote host produced \(rows.count) rows")
    }

    /// The cap must not be the bug: an ordinary fleet machine with a handful
    /// of sessions has to come through whole.
    @Test("An ordinary reply is not truncated")
    func ordinaryReplyIsWhole() throws {
        let loaded = try descriptors()
        let rows = RemoteTmux.parse(reply(panes: 3), host: "example.invalid") { loaded }
        #expect(rows.count == 3)
    }
}

/// Finding the pane a remote process sits in. The table this walks is parsed
/// from another machine's `ps` output — text, not a kernel structure — so the
/// shapes a real process tree cannot take are exactly the ones worth testing.
@Suite("The remote pane walk is bounded")
struct RemotePaneWalkTests {

    private typealias Pane = (target: String, cwd: String)

    /// `n` processes, each the child of the one before, with pid 100 at the
    /// bottom and the pane attached to the top.
    private func chain(_ n: Int) -> (pid: Int32, parents: [Int32: Int32], panes: [Int32: Pane]) {
        var parents: [Int32: Int32] = [:]
        for step in 0..<n { parents[100 + Int32(step)] = 100 + Int32(step) + 1 }
        return (100, parents, [100 + Int32(n): ("%1", "/synthetic/project")])
    }

    @Test("A process in the pane itself is found without walking")
    func direct() {
        let found = RemoteTmux.containingPane(
            of: 100, parents: [:], panes: [100: ("%0", "/synthetic/project")])
        #expect(found?.target == "%0")
    }

    /// The depths are written out rather than derived from
    /// `maxPaneDepth`, because a test that says "one less than the bound"
    /// passes for every bound and so asserts nothing about this one. Lowering
    /// the constant has to break a test, or it is not a decision anybody
    /// made.
    @Test("The bound is eight levels")
    func boundIsEight() {
        #expect(RemoteTmux.maxPaneDepth == 8)
    }

    /// A shell wrapper or `npx` puts the agent a level or two below the pane,
    /// which is the case the walk exists for.
    @Test("A process seven levels below its pane is still found")
    func withinBound() {
        let deep = chain(7)
        #expect(RemoteTmux.containingPane(of: deep.pid, parents: deep.parents,
                                          panes: deep.panes)?.target == "%1",
                "the walk gave up before reaching the pane")
    }

    /// The bound is the reason `while true` would behave identically on every
    /// well-formed table: this is the shape that tells them apart.
    @Test("A process eight levels below its pane is not attributed to it")
    func beyondBound() {
        let deep = chain(8)
        #expect(RemoteTmux.containingPane(of: deep.pid, parents: deep.parents,
                                          panes: deep.panes) == nil,
                "the walk went further up the tree than its bound")
    }

    /// No kernel produces this. A far side sending malformed `ps` output can,
    /// and an unbounded walk over it never returns — which is why removing
    /// the bound hangs this suite rather than failing it. The two tests above
    /// fail cleanly on the same mutation; this one is here because a cycle is
    /// the shape that turns an unbounded walk from wrong into fatal.
    @Test("A parent cycle terminates instead of looping forever")
    func cycle() {
        let found = RemoteTmux.containingPane(
            of: 100, parents: [100: 101, 101: 102, 102: 100], panes: [:])
        #expect(found == nil)
    }

    @Test("A chain that runs out before any pane finds nothing")
    func noPane() {
        #expect(RemoteTmux.containingPane(of: 100, parents: [100: 101], panes: [:]) == nil)
    }

    /// Walking into pid 1 means the process was reparented after its pane
    /// died; launchd is not anybody's tmux pane.
    @Test("The walk stops below init rather than claiming its pane")
    func stopsBelowInit() {
        let found = RemoteTmux.containingPane(
            of: 100, parents: [100: 1], panes: [1: ("%0", "/synthetic/project")])
        #expect(found == nil)
    }
}
