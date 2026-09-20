import Foundation
import Testing
@testable import Antarium

@Suite("Bounded historical trace reader")
struct BoundedTraceReaderTests {
    @Test("Read work and record memory are bounded while oversized records make progress")
    func oversized() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-trace-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((String(repeating: "x", count: 101) + "\n{\"ok\":1}\n").utf8).write(to: file)
        var state = BoundedTraceReader.State()
        var records: [String] = []
        var skipped = 0
        for _ in 0..<20 {
            let batch = try BoundedTraceReader.read(file, state: state, maxRead: 16, maxRecord: 32) {
                records.append(String(decoding: $0, as: UTF8.self))
            }
            state = batch.state; skipped += batch.skipped
            #expect(batch.bytesRead <= 16)
            if !batch.backlogged { break }
        }
        #expect(skipped == 1)
        #expect(records == ["{\"ok\":1}"])
    }
    @Test("An incomplete line resumes once and a replacement resets the cursor")
    func partialAndRotation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-trace-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("first\npart".utf8).write(to: file)
        var lines: [String] = []
        let first = try BoundedTraceReader.read(file, state: .init()) { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(lines == ["first"])
        #expect(first.state.offset == 6)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("ial\n".utf8)); try handle.close()
        let next = try BoundedTraceReader.read(file, state: first.state) { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(lines == ["first", "partial"])
        try Data("other\ncontent\n".utf8).write(to: file, options: .atomic)
        let replaced = try BoundedTraceReader.read(file, state: next.state) { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(replaced.reset)
        #expect(lines.suffix(2) == ["other", "content"])
    }
}
