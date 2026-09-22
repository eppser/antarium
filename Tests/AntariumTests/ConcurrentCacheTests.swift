import Foundation
import Testing
@testable import Antarium

/// The caches, used the way the app uses them: from several threads at once.
///
/// Twelve files here hold a lock and two had a test that ever contended one.
/// A strict-concurrency build proves the types line up, not that a
/// read-modify-write is atomic — and these caches are read from a menu bar
/// refresh, a background scan and a settings panel at the same time.
@Suite("Caches under contention", .serialized)
struct ConcurrentCacheTests {

    /// A counter that does not itself need the thing under test to work.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// `ConfiguredProbe` exists because two of the answers it memoises are
    /// expensive — one runs `/usr/bin/security`, one opens a SQLite database
    /// — and its comment says concurrent first probes are serialised
    /// deliberately, "since the alternative is several `security` subprocesses
    /// racing for the same answer". That is a claim about behaviour under
    /// contention and nothing tested it.
    @Test("A first probe from many threads at once runs the work once")
    func probeComputesOnce() {
        ConfiguredProbe.invalidate()
        let key = "concurrent-\(UUID().uuidString)"
        let computes = Counter()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            _ = ConfiguredProbe.value(key) {
                computes.increment()
                return true
            }
        }
        #expect(computes.count == 1,
                Comment(rawValue: "the work ran \(computes.count) times for one key"))
        ConfiguredProbe.invalidate()
    }

    @Test("Every caller of a contended probe gets the same answer")
    func probeIsConsistent() {
        ConfiguredProbe.invalidate()
        let key = "consistent-\(UUID().uuidString)"
        let answers = Counter()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if ConfiguredProbe.value(key, { true }) { answers.increment() }
        }
        #expect(answers.count == 64, "some callers saw a different answer")
        ConfiguredProbe.invalidate()
    }

    /// Different keys must not serialise into one answer, which is the
    /// mistake a single shared entry would make.
    @Test("Separate agents keep separate answers under contention")
    func probeKeepsKeysApart() {
        ConfiguredProbe.invalidate()
        let yes = "yes-\(UUID().uuidString)", no = "no-\(UUID().uuidString)"
        let wrong = Counter()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let key = i.isMultiple(of: 2) ? yes : no
            let got = ConfiguredProbe.value(key) { key == yes }
            if got != (key == yes) { wrong.increment() }
        }
        #expect(wrong.count == 0, "\(wrong.count) callers got another agent's answer")
        ConfiguredProbe.invalidate()
    }

    /// Invalidating while others are reading is the shape a sign-in takes:
    /// the settings panel clears the memo on the main thread while a refresh
    /// is already probing. Nothing here asserts a winner — there is no
    /// correct one — only that it neither crashes nor returns something that
    /// was never computed.
    @Test("Invalidating during a read is safe")
    func invalidateDuringRead() {
        let key = "racing-\(UUID().uuidString)"
        let bad = Counter()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            if i.isMultiple(of: 8) {
                ConfiguredProbe.invalidate(key)
            } else if ConfiguredProbe.value(key, { true }) != true {
                bad.increment()
            }
        }
        #expect(bad.count == 0, "a caller saw an answer nothing computed")
        ConfiguredProbe.invalidate()
    }

    /// The transcript cache is read by every scan and written by the same
    /// pass. Two scans overlapping is ordinary — a menu bar refresh and the
    /// dashboard's own timer — and the figures must not tear.
    @Test("Reading one transcript from many threads gives one answer")
    func transcriptStatsAreConsistent() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("concurrent-\(UUID().uuidString).jsonl")
        let line = #"{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":5}}}"#
        try Data((Array(repeating: line, count: 200).joined(separator: "\n") + "\n").utf8)
            .write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let results = Counter(), mismatches = Counter()
        let first = TranscriptStats.of(file)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let stats = TranscriptStats.of(file)
            results.increment()
            if stats?.sentTokens != first?.sentTokens { mismatches.increment() }
        }
        #expect(results.count == 32)
        #expect(mismatches.count == 0,
                Comment(rawValue: "\(mismatches.count) of 32 reads disagreed"))
    }
}
