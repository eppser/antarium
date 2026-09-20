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
