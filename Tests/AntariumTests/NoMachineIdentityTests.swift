import Foundation
import Testing
@testable import Antarium

/// The repository must not carry the identity of the machine it was written
/// on.
///
/// This is not hypothetical. The author's hostname was used as the example
/// host in the README, in two settings-panel help strings the user reads,
/// in a diagnostic message, and twenty-six times across the tests — thirty-
/// six occurrences in six files, published to a public remote before anybody
/// noticed. A name like that reads as a placeholder to whoever wrote it and
/// as somebody's machine to everybody else.
///
/// This test is deliberately about the machine it runs on. On a clean
/// checkout it checks that machine's identity instead, which is the point:
/// it protects whoever is about to commit, and the person about to commit is
/// the only one who can leak their own name.
@Suite("The repository carries nobody's machine")
struct NoMachineIdentityTests {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Everything git would carry, read once.
    private func trackedText() throws -> [(name: String, text: String)] {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "ls-files"]
        let pipe = Pipe()
        git.standardOutput = pipe
        git.standardError = Pipe()
        try git.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        let paths = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        return paths.compactMap { path in
            let url = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (path, text)
        }
    }

    @Test("There are tracked files to examine")
    func thereAreFiles() throws {
        let files = try trackedText()
        #expect(files.count > 50,
                Comment(rawValue: "only \(files.count) tracked files were read, so this "
                        + "proved nothing"))
    }

    /// A name short or common enough to appear by coincidence is not evidence
    /// of anything, and failing on it would teach people to ignore this test.
    private func isDistinctive(_ name: String) -> Bool {
        name.count >= 5 && !["build", "local", "macbook", "imac", "admin", "runner",
                             "ubuntu", "darwin", "localhost"].contains(name.lowercased())
    }

    /// Every name this machine answers to, not one of them.
    ///
    /// This asked `ProcessInfo.processInfo.hostName`, took the part before the
    /// first dot, and `#require`d it to be distinctive. Two problems, and the gate
    /// found them together by failing twice on a run where nothing had changed.
    ///
    /// `hostName` is the *network* name, so it resolves differently from moment to
    /// moment: the run that failed reported a two-letter name matching the account
    /// rather than the machine, where every other run reports the machine. A check
    /// whose subject changes between runs fails for reasons unrelated to the code.
    /// (Naming the value here would put this machine in the repository, which is
    /// what this test forbids — and it caught exactly that on the first attempt.)
    ///
    /// And `#require` is not a skip: when the name came back too generic to search
    /// for, the test *failed* — the exact outcome the comment above it warns
    /// against, since a test that fails on the machine rather than on the
    /// repository is a test people learn to ignore.
    ///
    /// Both fixed by asking every name available and searching for each that is
    /// distinctive. More names is a stronger check, and no distinctive name at all
    /// is a run that proved nothing, said out loud rather than failed.
    @Test("No name this machine answers to is in the repository")
    func hostnameIsAbsent() throws {
        var candidates: Set<String> = []
        for raw in [ProcessInfo.processInfo.hostName, Host.current().localizedName ?? "",
                    Host.current().name ?? ""] {
            let short = raw.split(separator: ".").first.map(String.init) ?? raw
            if !short.isEmpty { candidates.insert(short) }
        }
        let searchable = candidates.filter(isDistinctive).sorted()
        guard !searchable.isEmpty else {
            #expect(Bool(true), Comment(rawValue: "none of \(candidates.sorted()) is distinctive "
                                        + "enough to search for, so this run proved nothing"))
            return
        }
        let files = try trackedText()
        var found: [String] = []
        for name in searchable {
            for (path, text) in files
            where text.range(of: name, options: .caseInsensitive) != nil {
                found.append("\(path) (\(name))")
            }
        }
        #expect(found.isEmpty,
                Comment(rawValue: "this machine's name appears in \(found.sorted().joined(separator: ", "))"
                        + " — it reads as a placeholder to you and as somebody's machine to "
                        + "everybody else"))
    }

    /// And the home directory, which carries the account name.
    @Test("No home directory path is in the repository")
    func homePathIsAbsent() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = String(home.split(separator: "/").last ?? "")
        try #require(isDistinctive(user) || user.count >= 2,
                     "there is no account name to search for")
        var found: [String] = []
        for (path, text) in try trackedText() where text.contains(home) {
            found.append(path)
        }
        #expect(found.isEmpty,
                Comment(rawValue: "an absolute home path appears in "
                        + found.sorted().joined(separator: ", ")))
    }

    /// Example hosts in the documentation are recognisably examples.
    ///
    /// Only quoted hosts in Markdown, because that is where a reader takes a
    /// name to be a suggestion. The first version asked every line that
    /// merely mentioned `remoteTmuxHosts`, which is most of the code that
    /// implements the feature.
    @Test("The documented example hosts are recognisably examples")
    func exampleHostsLookLikeExamples() throws {
        var checked = 0
        for (path, text) in try trackedText() where path.hasSuffix(".md") {
            for line in text.split(separator: "\n")
            where line.contains("\"") && (line.contains("remoteTmuxHosts")
                                         || line.contains("--remote-tmux")) {
                // Each quoted host on its own. Asking the whole line let a
                // machine name pass because an IP address sat beside it.
                let quoted = line.split(separator: "\"").enumerated()
                    .filter { $0.offset % 2 == 1 }.map { String($0.element) }
                // The setting's own name is quoted on the same line in JSON.
                let keys = ["remoteTmuxHosts", "--remote-tmux", "includeRemoteTmux"]
                for host in quoted where !keys.contains(host)
                    && (host.contains(".") || host.contains("-")) {
                    checked += 1
                    let ok = host.contains("build-box") || host.contains("example")
                        || host.hasPrefix("10.0.0.") || host.contains("<")
                        || host.contains("HOST") || host.contains("host")
                    #expect(ok, Comment(rawValue: "\(path): \"\(host)\" is not "
                                        + "recognisably an example"))
                }
            }
        }
        #expect(checked >= 1,
                "no documented example hosts were found, so this proved nothing")
    }
}
