import Foundation
import Testing
@testable import Antarium

/// `~/.antarium` holds the configuration, the diagnostic log, the transcript
/// cache, and the harness descriptors — which name commands the app runs. All
/// of it is created 0700, and the files inside 0600, so another account on the
/// machine can neither read them nor edit a descriptor into running something.
///
/// Nothing was checking that. Widening any of the three directories to 0755
/// left the whole suite green, which is how a mode gets "simplified" in a
/// refactor years later.
@Suite("Private directories", .serialized)
struct PrivateDirectoryTests {

    private func mode(_ url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    @Test("The settings file and its directory are private")
    func configurationIsPrivate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = ConfigurationFile(url: root.appendingPathComponent("config.json"))
        _ = file.set("probe", "value")

        #expect(mode(root) == 0o700, "settings directory is \(mode(root).map { String($0, radix: 8) } ?? "absent")")
        let settings = root.appendingPathComponent("config.json")
        #expect(mode(settings) == 0o600,
                "settings file is \(mode(settings).map { String($0, radix: 8) } ?? "absent")")
    }

    @Test("The diagnostic log and its directory are private")
    func logIsPrivate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLogFile(directory: root)
        #expect(log.append("probe line"))

        #expect(mode(root) == 0o700,
                "log directory is \(mode(root).map { String($0, radix: 8) } ?? "absent")")
        // The log carries paths and agent names from this machine.
        let file = root.appendingPathComponent("antarium.log")
        #expect(mode(file) == 0o600,
                "log file is \(mode(file).map { String($0, radix: 8) } ?? "absent")")
    }

    @Test("The harness folder is private, and so is every descriptor in it")
    func harnessFolderIsPrivate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-harness-\(UUID().uuidString)")
        let source = root.appendingPathComponent("shipped")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = source.appendingPathComponent("example.json")
        try JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "id": "example", "name": "Example",
            "process": [:], "source": ["kind": "none", "path": ""],
        ]).write(to: descriptor)

        let target = root.appendingPathComponent("harnesses")
        let result = HarnessSeed.run(directory: target, sources: [descriptor],
                                     schema: nil, readme: "readme")
        #expect(result.issues.isEmpty, "\(result.issues)")
        #expect(result.added == ["example.json"])

        #expect(mode(target) == 0o700,
                "harness directory is \(mode(target).map { String($0, radix: 8) } ?? "absent")")
        // A descriptor names commands the app will run, so a mode that let
        // another account edit one is a way to run code as this user.
        let seeded = target.appendingPathComponent("example.json")
        #expect(mode(seeded) == 0o600,
                "descriptor is \(mode(seeded).map { String($0, radix: 8) } ?? "absent")")
    }
}

/// Token counts come from a file the app does not control. A negative one is
/// malformed, and summing it would make usage and cost quietly wrong rather
/// than unavailable.
@Suite("Transcript usage arithmetic")
struct TranscriptUsageGuardTests {

    @Test("A negative token count makes usage unavailable, not smaller")
    func negativeUsageIsRefused() {
        var stats = TranscriptStats()
        // Called outside #expect: it is mutating, and the macro captures its
        // receiver immutably.
        var accepted = stats.recordUsage(model: "m", input: 10, output: 5,
                                         cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(accepted)
        #expect(stats.usageIssue == nil)
        #expect(stats.hasUsageFacts)

        // One bad record poisons the total rather than being folded in.
        accepted = stats.recordUsage(model: "m", input: -1, output: 0,
                                     cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(!accepted)
        #expect(stats.usageIssue != nil)
        #expect(stats.costUSD == nil, "a poisoned total must not be priced")

        // And it stays refused: a later good record cannot clear it.
        accepted = stats.recordUsage(model: "m", input: 1, output: 1,
                                     cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(!accepted)
        #expect(stats.usageIssue != nil)
    }

    @Test("An overflowing total is unavailable rather than wrapped")
    func overflowIsRefused() {
        var stats = TranscriptStats()
        var accepted = stats.recordUsage(model: "m", input: Int.max, output: 0,
                                         cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(accepted)
        accepted = stats.recordUsage(model: "m", input: Int.max, output: 0,
                                     cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(!accepted)
        #expect(stats.usageIssue != nil)
        #expect(stats.costUSD == nil)
    }
}
