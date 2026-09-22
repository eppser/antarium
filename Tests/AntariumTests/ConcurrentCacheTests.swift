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

    /// A set that does not itself need the thing under test to work.
    private final class IdentitySet: @unchecked Sendable {
        private let lock = NSLock()
        private var values: Set<ObjectIdentifier> = []
        func insert(_ value: ObjectIdentifier) { lock.lock(); values.insert(value); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    }

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

    /// The catalogue is read on every scan, every settings draw and every
    /// menu build, and it rebuilds itself from disk inside the same lock. Two
    /// readers arriving while it rebuilds is the ordinary case, not a corner.
    @Test("Reading the catalogue from many threads gives one answer")
    func catalogueIsConsistent() {
        // Seeded first: on a machine where this app has never run there is
        // no harness folder yet, and a test that reads one is a test of
        // whoever ran it last. The bare-machine step in verify.sh exists to
        // catch exactly that, and caught this.
        HarnessDescriptor.seed()
        let first = HarnessDescriptor.all().map(\.id).sorted()
        #expect(!first.isEmpty, "no harnesses were seeded, so this proved nothing")
        let mismatches = Counter()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if HarnessDescriptor.all().map(\.id).sorted() != first { mismatches.increment() }
        }
        #expect(mismatches.count == 0,
                Comment(rawValue: "\(mismatches.count) of 32 reads saw a different catalogue"))
    }

    /// And while it is being rebuilt, which is what editing a harness file
    /// does from the settings panel while a scan is already running.
    ///
    /// Every thread forces the rebuild rather than only a few: reading a
    /// cached snapshot touches almost nothing shared, so a version of this
    /// that invalidated occasionally passed perfectly well with the lock
    /// removed. The contention has to be on the path that writes.
    ///
    /// Weaker than the others here, and worth saying so. Removing this
    /// lock is *not* caught: sixty-four threads rebuilding at once, half of
    /// them invalidating again mid-flight, still agree on the answer. The
    /// rebuild spends most of its time reading twenty-five files, so the
    /// writes at the end rarely overlap. This holds that concurrent
    /// rebuilds agree — which is worth holding — and it does not
    /// demonstrate the lock is load-bearing, so there is no catalogue entry
    /// for it. The probe and the engine below do both; this one does one.
    @Test("Rebuilding the catalogue from several threads at once is safe")
    func catalogueRebuildUnderContention() {
        HarnessDescriptor.seed()
        let expected = HarnessDescriptor.all().map(\.id).sorted()
        #expect(!expected.isEmpty, "no harnesses were seeded, so this proved nothing")
        let wrong = Counter()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            HarnessDescriptor.reload()
            // Half of them invalidate again mid-flight, so a rebuild is
            // running while another thread resets the state it is writing.
            if i.isMultiple(of: 2) { HarnessDescriptor.reload() }
            if HarnessDescriptor.all().map(\.id).sorted() != expected { wrong.increment() }
        }
        #expect(wrong.count == 0,
                Comment(rawValue: "\(wrong.count) of 64 rebuilds produced a different catalogue"))
    }

    /// The session engine holds the figures every row is drawn from. A menu
    /// bar refresh and the dashboard's own timer scan at the same time.
    @Test("Reading sessions from many threads gives one answer")
    func sessionsAreConsistent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<4 {
            let line = #"{"cwd":"/synthetic/p\#(i)","usage":{"in":\#(i * 10),"out":\#(i)}}"# + "\n"
            try Data(line.utf8).write(to: root.appendingPathComponent("s\(i).jsonl"))
        }
        let descriptor = try HarnessDocument.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "id": "engine", "name": "Engine", "process": [:],
            "source": ["kind": "jsonl", "path": root.path, "glob": "*.jsonl"],
            "map": ["cwd": "cwd", "inputTokens": "usage.in", "outputTokens": "usage.out"],
        ])).descriptor

        let first = HarnessEngine.sessions(descriptor).map(\.cwd).sorted { ($0 ?? "") < ($1 ?? "") }
        #expect(first.count == 4, "the fixture did not produce four sessions")
        // Each pass clears the parsed-file cache first, so every thread is
        // writing into the engine rather than reading a warm dictionary.
        // Reading a warm one contends almost nothing, and a version of this
        // that only read passed with the lock removed.
        let mismatches = Counter()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            HarnessEngine.resetCaches(includingParsedFiles: true)
            let got = HarnessEngine.sessions(descriptor).map(\.cwd)
                .sorted { ($0 ?? "") < ($1 ?? "") }
            if got != first { mismatches.increment() }
        }
        #expect(mismatches.count == 0,
                Comment(rawValue: "\(mismatches.count) of 16 scans disagreed"))
    }

    /// The provider registry keeps one `DescriptorProvider` per descriptor
    /// on purpose: each owns a URLSession, and a session holds its delegate
    /// until it is invalidated, so a second instance for the same harness is
    /// a leak that grows every time the file is re-read. The registry is
    /// built from a SwiftUI body and from the refresh loop, which is two
    /// threads asking at once.
    @Test("Building the registry from many threads keeps one provider per harness")
    func registryKeepsOneProviderEach() {
        // A harness nothing has asked about yet, so every thread below misses
        // the cache and writes. Reading a warm one races nothing, and the
        // registry is static: by the time any test runs, the shipped
        // harnesses have long since been built by another.
        let id = "race-\(UUID().uuidString)"
        let descriptor = try? HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: [
                "formatVersion": 1, "id": id, "name": "Race", "process": [:],
                "source": ["kind": "none", "path": ""],
                "quota": ["endpoint": "https://example.invalid/u",
                          "credential": ["kind": "textFile", "path": "~/.antarium/keys/race"],
                          "windows": ["single": "info", "usedPercent": "info.pct"]],
            ])).descriptor
        guard let descriptor else {
            Issue.record("the synthetic descriptor did not decode")
            return
        }

        let identities = IdentitySet()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if let provider = ProviderRegistry.providers(from: [descriptor])
                .first(where: { $0.id == id }) {
                identities.insert(ObjectIdentifier(provider as AnyObject))
            }
        }
        #expect(identities.count == 1,
                Comment(rawValue: "\(identities.count) separate providers were made for one "
                        + "harness, which is that many URLSessions"))
    }

    @Test("Every caller of a contended registry sees the same providers")
    func registryIsConsistent() {
        HarnessDescriptor.seed()
        let expected = ProviderRegistry.all.map(\.id).sorted()
        #expect(!expected.isEmpty)
        let wrong = Counter()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if ProviderRegistry.all.map(\.id).sorted() != expected { wrong.increment() }
        }
        #expect(wrong.count == 0,
                Comment(rawValue: "\(wrong.count) of 32 builds disagreed"))
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
