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
