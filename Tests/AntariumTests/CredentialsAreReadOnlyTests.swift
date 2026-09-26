import Foundation
import Testing
@testable import Antarium

/// No provider writes to another application's files.
///
/// Two of them say so about themselves. Grok's: "The refreshed token is held
/// in memory and never written back." Claude's: "Deliberately read-only: we
/// never refresh or rotate the token." Both are true today and neither was
/// held by anything — and the tempting change is an obvious one. A refreshed
/// token expires in an hour, so persisting it looks like a kindness until the
/// write races the agent's own, or truncates the file, and the user is signed
/// out of the thing they were using.
///
/// These files belong to other applications. This app reads them, bounded,
/// and puts nothing back. Checked in the source because the alternative is a
/// test that writes to somebody's real credential store to prove it does not.
@Suite("Providers read credentials and write nothing")
struct CredentialsAreReadOnlyTests {

    private var providers: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Sources/Antarium/Providers"),
            includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "swift" } ?? []
    }

    /// Every way this project actually writes, moves or removes a file.
    ///
    /// The first version of this list was written from memory and matched
    /// neither of the two files that certainly do write: the settings store
    /// goes through `open`/`Darwin.write`/`rename`, and the seeder through
    /// `PrivateFile.write`. A rule listing spellings nobody uses forbids
    /// nothing, and the control below is what said so.
    private let writes = ["PrivateFile.write", "Darwin.write(", "createDirectory(",
                          "createFile(", "FileHandle(forWriting", "write(to",
                          "removeItem(", "moveItem(", "copyItem(",
                          "setAttributes(", "rename(", "unlink("]

    @Test("No provider writes, moves or deletes a file")
    func providersDoNotWrite() throws {
        #expect(providers.count >= 8, "only \(providers.count) providers were scanned")
        for url in providers {
            let text = try String(contentsOf: url, encoding: .utf8)
            for call in writes {
                #expect(!text.contains(call),
                        Comment(rawValue: "\(url.lastPathComponent) calls \(call) — these files "
                                + "belong to other applications"))
            }
        }
    }

    /// The check is only worth anything if those spellings are the ones this
    /// project actually uses, so it is asked of code that does write.
    @Test("The spellings checked are the ones this project writes with")
    func theCheckWouldNotice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // Two files that certainly do write: the settings store and the
        // harness seeder.
        for name in ["Sources/Antarium/Core/ConfigurationFile.swift",
                     "Sources/Antarium/Core/HarnessSeed.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(writes.contains { text.contains($0) },
                    Comment(rawValue: "\(name) writes files and matches none of the spellings, "
                            + "so the rule above would not notice a provider that did"))
        }
    }

    /// And the one provider that does cause a file to change says how: it
    /// runs the vendor's own CLI, which rewrites its own credential. That is
    /// the agent writing its file, not this app.
    @Test("A refreshed credential is obtained by asking the agent, not by writing")
    func refreshGoesThroughTheAgent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let gemini = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/Providers/GeminiProvider.swift"), encoding: .utf8)
        #expect(gemini.contains("Shell.execute"),
                "the refresh no longer goes through the agent's own CLI")
        #expect(gemini.contains("rewrites"),
                "the reason the CLI is run is no longer written down")
    }
}
