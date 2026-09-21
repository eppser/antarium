import Darwin
import Foundation
import Testing
@testable import Antarium

@Suite("Bounded regular-file reads")
struct BoundedFileTests {
    @Test("Oversized, symbolic and special files fail before an unbounded read")
    func rejectedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-file-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), link = root.appendingPathComponent("link"), fifo = root.appendingPathComponent("pipe")
        try Data(repeating: 1, count: 1_025).write(to: file)
        #expect(throws: (any Error).self) { try BoundedFile.read(file, maxBytes: 1_024) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try BoundedFile.read(link) }
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try BoundedFile.read(fifo) }
        #expect(throws: (any Error).self) { try BoundedFile.prefix(fifo,maxBytes:32) }
        #expect(throws: (any Error).self) { try BoundedFile.prefix(link,maxBytes:32) }
        #expect(try BoundedFile.prefix(file,maxBytes:32).count == 32)
        #expect(!BoundedFile.isRegular(fifo))
    }
    @Test("JSONL samples retain both ends without loading the whole file")
    func headAndTail() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-file-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let middle = "{\"padding\":\"" + String(repeating: "x", count: 1_000) + "\"}\n"
        try Data(("{\"which\":\"first\"}\n" + String(repeating: middle, count: 5_000) + "{\"which\":\"last\"}\n").utf8).write(to: file)
        let sample = try BoundedFile.sampleJSONL(file, maxRecords: 20)
        #expect(sample.bytesRead <= 2 * 1_024 * 1_024)
        #expect(sample.records.count <= 20)
        #expect(sample.limited)
        let objects = sample.records.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(objects.first?["which"] as? String == "first")
        #expect(objects.last?["which"] as? String == "last")
    }
}

/// The ordinary path. The suite covered oversized, symbolic and special files
/// — the boundaries — and not that a normal file comes back intact, which is
/// what every other reader in this project depends on.
@Suite("Bounded reads return the file")
struct BoundedFileOrdinaryTests {

    private func file(_ bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-\(UUID()).bin")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    @Test("A file within the cap comes back byte for byte")
    func exactContents() throws {
        let url = try file(4_096)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try BoundedFile.read(url, maxBytes: 1_048_576)
        #expect(read.count == 4_096)
        #expect(read == (try Data(contentsOf: url)), "the bytes differ from the file")
    }

    @Test("An empty file reads as empty rather than failing")
    func emptyFile() throws {
        let url = try file(0)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try BoundedFile.read(url).isEmpty)
    }

    /// The cap is inclusive, and one byte past it is not. Both sides matter:
    /// a reader that refuses a file exactly at its limit rejects legitimate
    /// input, and one that accepts a byte more has no limit.
    @Test("A file exactly at the cap is read; one byte more is refused")
    func capIsExact() throws {
        let atCap = try file(1_024)
        defer { try? FileManager.default.removeItem(at: atCap) }
        #expect(try BoundedFile.read(atCap, maxBytes: 1_024).count == 1_024)

        let over = try file(1_025)
        defer { try? FileManager.default.removeItem(at: over) }
        #expect(throws: BoundedFile.ReadError.tooLarge) {
            _ = try BoundedFile.read(over, maxBytes: 1_024)
        }
    }

    @Test("A prefix read returns the requested length, not the whole file")
    func prefixLength() throws {
        let url = try file(8_192)
        defer { try? FileManager.default.removeItem(at: url) }
        let head = try BoundedFile.prefix(url, maxBytes: 100)
        #expect(head.count == 100)
        #expect(head == (try Data(contentsOf: url)).prefix(100), "the wrong 100 bytes")
    }

    @Test("A prefix longer than the file is the whole file")
    func prefixBeyondEnd() throws {
        let url = try file(10)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try BoundedFile.prefix(url, maxBytes: 1_000).count == 10)
    }
}

/// The glob search that finds a harness's session files. Its boundaries —
/// entry limits, directory limits, cycles — are covered elsewhere; what it
/// actually returns was not.
@Suite("Glob search returns the right files, in a stable order")
struct BoundedDirectoryGlobTests {

    private func tree(_ build: (URL) throws -> Void) rethrows -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("glob-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ root: URL, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: url)
    }

    @Test("A pattern finds the files that match it and not the others")
    func findsMatches() throws {
        let root = try tree {
            try write($0, "a.jsonl"); try write($0, "b.jsonl"); try write($0, "c.txt")
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try BoundedGlob.files(under: root, pattern: "*.jsonl")
        #expect(found.map(\.lastPathComponent) == ["a.jsonl", "b.jsonl"])
    }

    /// A directory can match a file pattern — `sessions.jsonl/` is a legal
    /// name — and handing one to a file reader is a read that fails for a
    /// reason nobody will understand.
    @Test("A directory whose name matches the pattern is not a file")
    func directoriesAreNotFiles() throws {
        let root = try tree {
            try write($0, "real.jsonl")
            try FileManager.default.createDirectory(
                at: $0.appendingPathComponent("decoy.jsonl"), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try BoundedGlob.files(under: root, pattern: "*.jsonl")
        #expect(found.map(\.lastPathComponent) == ["real.jsonl"])
    }

    /// The order is the sort, not the filesystem's. Two machines with the
    /// same files must produce the same list, for the same reason first-run
    /// detection breaks its ties on id.
    @Test("Results come back sorted, whatever order the filesystem gives")
    func orderIsStable() throws {
        let names = ["z.jsonl", "m.jsonl", "a.jsonl", "b.jsonl", "y.jsonl"]
        let root = try tree { for name in names { try write($0, name) } }
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try BoundedGlob.files(under: root, pattern: "*.jsonl")
        #expect(found.map(\.lastPathComponent) == names.sorted())
        // And again, to catch an order that is stable only by luck of hashing.
        let again = try BoundedGlob.files(under: root, pattern: "*.jsonl")
        #expect(again == found)
    }

    @Test("A recursive pattern descends, and still returns only files")
    func recursivePattern() throws {
        let root = try tree {
            try write($0, "top.jsonl")
            try write($0, "one/nested.jsonl")
            try write($0, "one/two/deep.jsonl")
            try FileManager.default.createDirectory(
                at: $0.appendingPathComponent("one/dir.jsonl"), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try BoundedGlob.files(under: root, pattern: "**/*.jsonl")
            .map(\.lastPathComponent).sorted()
        #expect(found == ["deep.jsonl", "nested.jsonl", "top.jsonl"])
    }

    @Test("A pattern matching nothing finds nothing rather than everything")
    func noMatches() throws {
        let root = try tree { try write($0, "a.txt") }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try BoundedGlob.files(under: root, pattern: "*.jsonl").isEmpty)
    }
}
