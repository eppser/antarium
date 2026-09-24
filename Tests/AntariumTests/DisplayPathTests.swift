import Foundation
import Testing
@testable import Antarium

/// Shortening a working directory to `~/…` for the row and the alert.
///
/// The counterpart to [TildeExpansionTests]: that one covers turning a tilde
/// back into a path, this one covers making the tilde in the first place.
/// Both were a bare prefix test, and both fabricated a path because of it.
///
/// Homes are synthetic here. The case that was wrong needs a second account
/// whose name extends this one's, which cannot be built from whatever home
/// the machine running the tests happens to have — and naming a real account
/// is exactly what this repository's fixtures may not do.
@Suite("A path is shortened only where the tilde would mean this account")
struct DisplayPathTests {

    private let home = "/synthetic/users/se"

    private func shown(_ cwd: String, home: String? = nil) -> String {
        AgentRow.displayPath(cwd, home: home ?? self.home)
    }

    @Test("A directory inside this home is shortened")
    func insideHome() {
        #expect(shown("\(home)/shared/spicy") == "~/shared/spicy")
        #expect(shown("\(home)/x") == "~/x")
        #expect(shown(home) == "~")
    }

    /// The defect. `/synthetic/users/sebastian` is not inside
    /// `/synthetic/users/se`, but it does begin with those characters, and
    /// the row showed `~bastian/project` — a path that names nothing, on a
    /// machine where two accounts have ordinary related names.
    @Test("A sibling account whose name extends this one is not clipped",
          arguments: ["/synthetic/users/sebastian/project",
                      "/synthetic/users/second/work",
                      "/synthetic/users/se-backup/project",
                      "/synthetic/users/se.old/x",
                      "/synthetic/users/september"])
    func siblingAccounts(cwd: String) {
        let text = shown(cwd)
        #expect(text == cwd, Comment(rawValue: "\(cwd) was shown as \(text)"))
        #expect(!text.hasPrefix("~"),
                Comment(rawValue: "\(cwd) was shortened as though it were in this home"))
    }

    @Test("A directory outside this home keeps its path",
          arguments: ["/Volumes/work/project", "/opt/src", "/", "/synthetic/users",
                      "/synthetic", "relative/path"])
    func outsideHome(cwd: String) {
        #expect(shown(cwd) == cwd)
    }

    @Test("No working directory shows no path")
    func noPath() {
        #expect(shown("") == "")
    }

    /// A home that would make the prefix test match everything. Neither is a
    /// path worth shortening against, and both used to turn ordinary paths
    /// into tilde paths that name nothing.
    @Test("An unusable home shortens nothing", arguments: ["", "/"])
    func degenerateHome(home: String) {
        #expect(shown("/synthetic/users/se/project", home: home) == "/synthetic/users/se/project")
        #expect(shown("/opt/src", home: home) == "/opt/src")
    }

    /// The two halves of the journey are inverses, and the shortened form is
    /// only correct if it can be read back. This is what a bare prefix test
    /// broke at both ends: the old pair round-tripped `~bastian/project` to
    /// the right path by cancelling each other's mistake, which is not the
    /// same as either being right.
    @Test("A shortened path expands back to the path it came from",
          arguments: ["/shared/spicy", "/x", "/a/b/c/d", "/.claude/projects", ""])
    func roundTrip(suffix: String) {
        let real = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = real + suffix
        let short = AgentRow.displayPath(cwd, home: real)
        #expect(short.hasPrefix("~"),
                Comment(rawValue: "a path in this home was not shortened"))
        #expect(short.expandingTilde == cwd,
                Comment(rawValue: "shortened to \(short), which expands elsewhere"))
    }

    /// And the shortening has to happen, or every assertion above about what
    /// is left alone would be satisfied by leaving everything alone.
    @Test("The row actually shortens the path it is given")
    func rowShortens() {
        let real = FileManager.default.homeDirectoryForCurrentUser.path
        let row = AgentRow(id: "r", agentID: "claude-code", name: "p",
                           cwd: real + "/work", state: .waiting, lastActivity: nil,
                           costUSD: nil, hostApp: nil)
        #expect(row.displayPath == "~/work")
    }
}
