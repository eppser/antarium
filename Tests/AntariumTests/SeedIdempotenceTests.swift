import Foundation
import Testing
@testable import Antarium

/// What an upgrade is allowed to do to the harness folder. The folder is the
/// user's — it is the only copy, and it is what the app reads — so the rules
/// are about what must not be touched.
@Suite("Seeding is idempotent and leaves your edits alone", .serialized)
struct SeedIdempotenceTests {

    private func scratch() throws -> (home: URL, sources: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString)")
        let home = root.appendingPathComponent("harnesses")
        let ship = root.appendingPathComponent("shipped")
        for dir in [home, ship] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var sources: [URL] = []
        for name in ["alpha", "beta"] {
            let file = ship.appendingPathComponent("\(name).json")
            let object: [String: Any] = [
                "formatVersion": 1, "id": name, "name": name.capitalized,
                "process": [:], "source": ["kind": "none", "path": ""]]
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            sources.append(file)
        }
        return (home, sources)
    }

    private func seed(_ home: URL, _ sources: [URL], readme: String = "instructions")
        -> HarnessSeed.Result {
        HarnessSeed.run(directory: home, sources: sources, schema: nil, readme: readme)
    }

    @Test("A first run writes every shipped harness")
    func firstRunWrites() throws {
        let (home, sources) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let result = seed(home, sources)
        #expect(result.added.sorted() == ["alpha.json", "beta.json"])
        #expect(result.updated.isEmpty)
        #expect(result.issues.isEmpty)
    }

    /// Rewriting identical bytes changes the modification time, and the parse
    /// cache is keyed on it — so a seed that is not idempotent re-reads every
    /// harness on every launch while looking like it did nothing.
    @Test("A second run writes nothing and leaves the files untouched")
    func secondRunIsQuiet() throws {
        let (home, sources) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        _ = seed(home, sources)
        let file = home.appendingPathComponent("alpha.json")
        let before = FileStamp.of(file)
        let result = seed(home, sources)
        #expect(result.added.isEmpty)
        #expect(result.updated.isEmpty)
        #expect(result.keptYours.isEmpty)
        #expect(FileStamp.of(file) == before, "an unchanged harness was rewritten")
    }

    @Test("A harness you edited is kept, and reported as kept")
    func editedFilesAreKept() throws {
        let (home, sources) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        _ = seed(home, sources)
        let file = home.appendingPathComponent("alpha.json")
        let mine = Data(#"{"formatVersion":1,"id":"alpha","name":"Mine","process":{},"source":{"kind":"none","path":""}}"#.utf8)
        try mine.write(to: file)

        let result = seed(home, sources)
        #expect(result.keptYours == ["alpha.json"])
        #expect(result.updated.isEmpty)
        #expect(try Data(contentsOf: file) == mine, "an edited harness was overwritten")
    }

    /// The other half: a file the app wrote and has not been touched must
    /// still be updated when the shipped copy changes, or a fix nobody
    /// receives is not a fix.
    @Test("An untouched harness is updated when the shipped copy changes")
    func untouchedFilesAreUpdated() throws {
        let (home, sources) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        _ = seed(home, sources)
        let newer: [String: Any] = [
            "formatVersion": 1, "id": "alpha", "name": "Alpha II",
            "process": [:], "source": ["kind": "none", "path": ""]]
        try JSONSerialization.data(withJSONObject: newer).write(to: sources[0])

        let result = seed(home, sources)
        #expect(result.updated == ["alpha.json"])
        #expect(result.keptYours.isEmpty)
        let landed = try JSONSerialization.jsonObject(
            with: Data(contentsOf: home.appendingPathComponent("alpha.json"))) as? [String: Any]
        #expect(landed?["name"] as? String == "Alpha II")
    }

    @Test("A README you rewrote is not replaced")
    func readmeIsNotOverwritten() throws {
        let (home, sources) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        _ = seed(home, sources, readme: "shipped text")
        let readme = home.appendingPathComponent("README.txt")
        #expect(try String(contentsOf: readme, encoding: .utf8) == "shipped text")

        try Data("my own notes".utf8).write(to: readme)
        _ = seed(home, sources, readme: "shipped text")
        #expect(try String(contentsOf: readme, encoding: .utf8) == "my own notes",
                "the README was replaced under the user")
    }

    @Test("A harness the user deleted comes back on the next run")
    func deletedHarnessIsRestored() throws {
        let (home, sources) = try scratch()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        _ = seed(home, sources)
        try FileManager.default.removeItem(at: home.appendingPathComponent("beta.json"))
        let result = seed(home, sources)
        #expect(result.added == ["beta.json"])
    }
}
