import Foundation
import Testing
@testable import Antarium

/// Turning a descriptor's `~/…` into a real path.
///
/// Twenty-nine call sites and no test of its own. Every harness source path,
/// every fixture existence check and — the one that matters — the command a
/// descriptor names, which `CommandPath` resolves and the app then runs.
///
/// It expanded any leading tilde by dropping one character and prepending
/// this account's home, which is right for `~/x` and wrong for everything
/// else. `~other/x` became `/Users/<you>other/x`: not another account's
/// home, which is what a shell would give, and not what anybody wrote.
@Suite("A tilde is expanded only where it means this account")
struct TildeExpansionTests {

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    @Test("A path in this account's home expands")
    func ordinaryPaths() {
        #expect("~".expandingTilde == home)
        #expect("~/".expandingTilde == home + "/")
        #expect("~/.codex".expandingTilde == home + "/.codex")
        #expect("~/.claude/projects".expandingTilde == home + "/.claude/projects")
    }

    @Test("A path that is already absolute or relative is untouched",
          arguments: ["/usr/bin/claude", "relative/path", "", "a~b", "./x", "..", "x~"])
    func untouchedPaths(path: String) {
        #expect(path.expandingTilde == path,
                Comment(rawValue: "\"\(path)\" became \"\(path.expandingTilde)\""))
    }

    /// The defect. A tilde this app cannot expand correctly is left alone, so
    /// it resolves to nothing — rather than being turned into a path that
    /// means nothing and might exist.
    @Test("A tilde naming another account is not glued onto this one",
          arguments: ["~other/x", "~root", "~~/x", "~-/x", "~1/x"])
    func otherAccountsAreNotFabricated(path: String) {
        let expanded = path.expandingTilde
        #expect(expanded == path,
                Comment(rawValue: "\"\(path)\" became \"\(expanded)\""))
        #expect(!expanded.hasPrefix(home),
                Comment(rawValue: "\"\(path)\" was expanded into this account's home"))
    }

    /// And what that protects. The command a descriptor names goes through
    /// this on its way to being looked up and run, so a fabricated path that
    /// happened to exist would be executed.
    @Test("A command naming another account resolves to nothing")
    func commandsAreNotFabricated() {
        #expect(CommandPath.resolve("~other/bin/tool", in: []) == nil)
        // And the ordinary case still works: an absolute path that exists
        // resolves to itself.
        #expect(CommandPath.resolve("/bin/sh", in: []) == "/bin/sh")
    }

    /// The expansion has to actually happen, or "nothing is fabricated" would
    /// be satisfied by expanding nothing at all.
    @Test("Expansion is not simply disabled")
    func expansionStillHappens() {
        #expect("~/.codex".expandingTilde != "~/.codex")
        #expect("~/.codex".expandingTilde.hasPrefix(home))
        #expect("~/.codex".expandingTilde.hasSuffix("/.codex"))
    }
}
