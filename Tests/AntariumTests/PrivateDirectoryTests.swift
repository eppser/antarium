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
        var accepted = stats.recordUsage(model: "claude-opus-5", input: 10, output: 5,
                                         cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(accepted)
        #expect(stats.usageIssue == nil)
        #expect(stats.hasUsageFacts)

        // One bad record poisons the total rather than being folded in.
        accepted = stats.recordUsage(model: "claude-opus-5", input: -1, output: 0,
                                     cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(!accepted)
        #expect(stats.usageIssue != nil)
        // The model deliberately has a published price, so a nil cost here can
        // only come from the usage issue. Using an unpriced model made this
        // pass whether or not the guard existed.
        #expect(Pricing.rate(for: "claude-opus-5") != nil, "test needs a priced model")
        #expect(stats.costUSD == nil, "a poisoned total must not be priced")

        // And it stays refused: a later good record cannot clear it.
        accepted = stats.recordUsage(model: "claude-opus-5", input: 1, output: 1,
                                     cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(!accepted)
        #expect(stats.usageIssue != nil)
    }

    @Test("An overflowing total is unavailable rather than wrapped")
    func overflowIsRefused() {
        var stats = TranscriptStats()
        var accepted = stats.recordUsage(model: "claude-opus-5", input: Int.max, output: 0,
                                         cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(accepted)
        accepted = stats.recordUsage(model: "claude-opus-5", input: Int.max, output: 0,
                                     cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
        #expect(!accepted)
        #expect(stats.usageIssue != nil)
        #expect(stats.costUSD == nil)
    }
}

/// Model names are prefixes, and several overlap: "claude-opus-4" is a prefix
/// of "claude-opus-4-1". Matching the shortest first would price a 4.1 session
/// at 4's rate — a wrong number, presented with the same confidence as a right
/// one.
@Suite("Pricing prefix resolution")
struct PricingPrefixTests {

    @Test("The most specific prefix wins")
    func longestPrefixWins() throws {
        // These two overlap as prefixes and are priced differently — opus-4 at
        // $15 per million input, opus-4-5 at $5. A pair priced the same could
        // not tell the two orders apart, which is how the first version of
        // this test was written.
        let general = try #require(Pricing.rate(for: "claude-opus-4"))
        let specific = try #require(Pricing.rate(for: "claude-opus-4-5"))
        #expect(general.input != specific.input,
                "this test needs two overlapping prefixes with different rates")

        // A real model id carries a date suffix and must still price as 4.5,
        // not as the shorter opus-4 it also begins with.
        let dated = try #require(Pricing.rate(for: "claude-opus-4-5-20260101"))
        #expect(dated.input == specific.input)
        #expect(dated.output == specific.output)
        #expect(dated.input != general.input,
                "a 4.5 session priced at opus-4's rate is a wrong number stated confidently")
    }

    @Test("An unknown model has no rate, rather than a free one")
    func unknownModelIsUnpriced() {
        #expect(Pricing.rate(for: "some-model-we-have-never-seen") == nil)
        #expect(Pricing.rate(for: nil) == nil)
        #expect(Pricing.rate(for: "") == nil)
    }
}
