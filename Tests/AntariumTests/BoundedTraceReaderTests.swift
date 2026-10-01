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

@Suite("Bounded trace reader, record boundaries")
struct BoundedTraceReaderBoundaryTests {

    private func write(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("btr-\(UUID().uuidString).jsonl")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// The reader was rewritten from a per-byte walk to a memchr search over
    /// each chunk. These pin the behaviour that rewrite had to preserve: the
    /// bytes it hands over, where the cursor lands, and which records it
    /// refuses — all across a chunk boundary, which is where an off-by-one in
    /// a scanner like this actually shows up.
    @Test("Records are delivered whole and in order, whatever the chunking")
    func recordsSurviveChunkBoundaries() throws {
        // Deliberately not a round number, so records straddle any chunk size.
        let records = (0..<500).map { "{\"n\":\($0),\"pad\":\"\(String(repeating: "x", count: $0 % 37))\"}" }
        let url = try write(records.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        var seen: [String] = []
        let batch = try BoundedTraceReader.read(url, state: .init()) { line in
            seen.append(String(decoding: line, as: UTF8.self))
        }
        #expect(seen == records)
        #expect(!batch.backlogged)
        #expect(batch.skipped == 0)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(batch.state.offset == UInt64(size ?? -1))
    }

    @Test("A resumed read continues exactly where the last complete record ended")
    func resumeDoesNotLoseOrRepeatARecord() throws {
        let records = (0..<200).map { "{\"n\":\($0)}" }
        let url = try write(records.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        // A tight read budget forces several resumes.
        var seen: [String] = []
        var state = BoundedTraceReader.State()
        var rounds = 0
        while rounds < 100 {
            let batch = try BoundedTraceReader.read(url, state: state, maxRead: 64) { line in
                seen.append(String(decoding: line, as: UTF8.self))
            }
            state = batch.state
            rounds += 1
            if !batch.backlogged { break }
        }
        #expect(rounds > 1, "the budget should have forced more than one pass")
        #expect(seen == records)
    }

    @Test("An oversized record is counted once and the next one still arrives")
    func oversizedRecordIsSkippedOnce() throws {
        let huge = "{\"pad\":\"" + String(repeating: "y", count: 4_000) + "\"}"
        let url = try write("{\"n\":1}\n" + huge + "\n{\"n\":2}\n")
        defer { try? FileManager.default.removeItem(at: url) }

        var seen: [String] = []
        let batch = try BoundedTraceReader.read(url, state: .init(), maxRecord: 64) { line in
            seen.append(String(decoding: line, as: UTF8.self))
        }
        // Counted once, not once per byte over the limit — the per-byte walk
        // could only ever report it as one because it reset `discarding`, and
        // the rewrite has to match that.
        #expect(batch.skipped == 1)
        #expect(seen == ["{\"n\":1}", "{\"n\":2}"])
    }

    @Test("The shipped record limit admits the records real transcripts contain")
    func defaultRecordLimitFitsRealRecords() throws {
        // Measured on this machine: the longest records in large transcripts
        // are about 1.36 MB, and four of eight had one. At a 1 MiB limit every
        // one of those sessions reported no usage at all — a skipped record
        // makes the totals incomplete, and an incomplete total is withheld
        // rather than shown low. Sessions worth $670 and $1380 displayed
        // nothing until this limit was raised.
        let record = String(repeating: "x", count: 1_400_000)
        let url = try write("{\"pad\":\"" + record + "\"}\n{\"n\":2}\n")
        defer { try? FileManager.default.removeItem(at: url) }

        var seen = 0
        let batch = try BoundedTraceReader.read(url, state: .init()) { _ in seen += 1 }
        #expect(batch.skipped == 0, "a 1.4 MB record was skipped at the shipped limit")
        #expect(seen == 2)
    }

    @Test("A record ending exactly on the limit is kept; one byte more is not")
    func recordLimitBoundary() throws {
        func skipped(bodyLength: Int, limit: Int) throws -> (Int, [String]) {
            let record = String(repeating: "z", count: bodyLength)
            let url = try write(record + "\n{\"n\":2}\n")
            defer { try? FileManager.default.removeItem(at: url) }
            var seen: [String] = []
            let batch = try BoundedTraceReader.read(url, state: .init(), maxRecord: limit) { line in
                seen.append(String(decoding: line, as: UTF8.self))
            }
            return (batch.skipped, seen)
        }
        let exact = try skipped(bodyLength: 64, limit: 64)
        #expect(exact.0 == 0)
        #expect(exact.1.first == String(repeating: "z", count: 64))

        let over = try skipped(bodyLength: 65, limit: 64)
        #expect(over.0 == 1)
        #expect(over.1 == ["{\"n\":2}"])
    }

    @Test("A trailing record with no newline is left for the next read")
    func trailingPartialRecordIsNotConsumed() throws {
        let url = try write("{\"n\":1}\n{\"n\":2")
        defer { try? FileManager.default.removeItem(at: url) }
        var seen: [String] = []
        let batch = try BoundedTraceReader.read(url, state: .init()) { line in
            seen.append(String(decoding: line, as: UTF8.self))
        }
        #expect(seen == ["{\"n\":1}"])
        // The cursor stops after the last complete record, so when the writer
        // finishes the line it is read once and whole.
        #expect(batch.state.offset == 8)
    }
}
