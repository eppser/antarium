import Foundation
import Testing
@testable import Antarium

/// `claudeRows` produces every Claude Code row there is. It is the reader for
/// the agent most users of this app actually run, it has the most rules in it
/// of any reader here — liveness, staleness, status mapping, identity — and
/// it had no tests at all, because it reads a live registry rather than going
/// through the descriptor fixture runner.
///
/// It takes its descriptor as a parameter, so none of that required Claude to
/// be installed. Everything below is synthetic JSON in a temporary directory.
@Suite("The Claude Code registry reader", .serialized)
struct ClaudeRegistryTests {

    private func descriptor(at root: URL) throws -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "claude-code", "name": "Claude Code",
            "process": ["pathContains": ["/claude/versions/"]],
            "source": ["kind": "none", "path": root.path,
                       "paths": ["transcripts": root.appendingPathComponent("projects").path]]]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    private func registry(_ entries: [String: [String: Any]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, body) in entries {
            try JSONSerialization.data(withJSONObject: body)
                .write(to: root.appendingPathComponent("\(name).json"))
        }
        return root
    }

    private func rows(_ entries: [String: [String: Any]],
                      processes: [Int32: Processes.Info] = [:]) throws -> [AgentRow] {
        let root = try registry(entries)
        defer { try? FileManager.default.removeItem(at: root) }
        return try AgentScan.claudeRows(try descriptor(at: root), processes: processes)
    }

    // MARK: - Shape

    @Test("A registry that does not exist is no sessions, not a failure")
    func absentRegistry() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString)")
        let found = try AgentScan.claudeRows(try descriptor(at: missing), processes: [:])
        #expect(found.isEmpty)
    }

    /// A process the descriptor claims, so the registry entry is live and the
    /// published status is actually consulted. Without this the state machine
    /// answers "ended" for everything and the status tests below cannot fail
    /// — which is exactly how the first version of them passed.
    private func liveProcess(_ pid: Int32) -> [Int32: Processes.Info] {
        [pid: Processes.Info(pid: pid, ppid: 1,
                             path: "/opt/claude/versions/2.1.0", name: "2.1.0",
                             argv0: "claude", rss: 1_024,
                             startedAt: Date(timeIntervalSince1970: 1))]
    }

    @Test("An entry with no live process reads as ended, not as working")
    func deadProcessIsNotBusy() throws {
        let found = try rows(["a": ["cwd": "/tmp/project", "pid": 999_999, "status": "busy"]])
        let row = try #require(found.first)
        #expect(row.pid == nil, "a pid nothing is running must not be reported as live")
        if case .working = row.state {
            Issue.record("a stale entry claiming busy was taken at its word")
        }
    }

    /// Claude Desktop publishes no `status` at all. Reading that as "busy"
    /// left those sessions showing Working for ever — the comment above the
    /// code said so and nothing held it.
    @Test("A live session that publishes no status is not read as busy")
    func absentStatusIsNotBusy() throws {
        let pid: Int32 = 4_242
        let found = try rows(["a": ["cwd": "/tmp/project", "pid": Int(pid)]],
                             processes: liveProcess(pid))
        let row = try #require(found.first)
        #expect(row.pid == pid, "the process must be live or this proves nothing")
        if case .working = row.state {
            Issue.record("no status was taken as busy")
        }
    }

    /// The counterpart: a live session that *does* publish busy must read as
    /// working, or the test above passes against a reader that ignores status
    /// altogether.
    @Test("A live session that publishes busy is read as busy")
    func publishedBusyIsHonoured() throws {
        let pid: Int32 = 4_243
        let found = try rows(["a": ["cwd": "/tmp/project", "pid": Int(pid), "status": "busy"]],
                             processes: liveProcess(pid))
        let row = try #require(found.first)
        #expect(row.pid == pid)
        if case .working = row.state {} else {
            Issue.record("a live busy session did not read as working, got \(row.state)")
        }
    }

    @Test("The row is named for the session, falling back to the directory")
    func naming() throws {
        let named = try rows(["a": ["cwd": "/tmp/project", "name": "Fixing the parser"]])
        #expect(named.first?.name == "Fixing the parser")
        let unnamed = try rows(["b": ["cwd": "/tmp/some-project"]])
        #expect(unnamed.first?.name == "some-project")
    }

    /// Claude reuses a session id across resumed sessions, so two live agents
    /// in different projects can share one. Identity has to include more than
    /// the session id or the list renders one of them twice.
    @Test("Two sessions sharing an id in different projects are two rows")
    func identityIsNotJustTheSessionID() throws {
        let found = try rows([
            "a": ["cwd": "/tmp/one", "sessionId": "shared", "pid": 999_998],
            "b": ["cwd": "/tmp/two", "sessionId": "shared", "pid": 999_999]])
        #expect(found.count == 2)
        #expect(Set(found.map(\.id)).count == 2, "two live sessions collapsed into one row")
    }

    @Test("A session with no transcript says so rather than leaving a blank row")
    func sdkSessionExplainsItself() throws {
        let found = try rows(["a": ["cwd": "/tmp/project", "entrypoint": "sdk"]])
        let note = try #require(found.first?.note)
        #expect(note.contains("sdk"))
        #expect(found.first?.sentTokens == nil, "nothing was read, so nothing is reported")
    }

    // MARK: - Refusals

    @Test("A malformed entry fails the read rather than being skipped", arguments: [
        ["pid": 1],                                        // no cwd
        ["cwd": 42],                                       // cwd is not text
        ["cwd": "/tmp/p", "pid": "not-a-pid"],             // pid present but unusable
        ["cwd": "/tmp/p", "startedAt": -1],                // before the epoch
        ["cwd": "/tmp/p", "updatedAt": 253_402_300_800_000], // past year 9999
        ["cwd": String(repeating: "x", count: 5_000)],     // over the path cap
        ["cwd": "/tmp/with\u{0007}control"],               // control characters
    ])
    func malformedEntriesAreRefused(_ entry: [String: Any]) throws {
        #expect(throws: (any Swift.Error).self) { try rows(["a": entry]) }
    }

    /// The refusals above would all pass against a reader that rejected
    /// everything, so this pins that the ordinary entry they are variations of
    /// is accepted.
    @Test("The entry those are variations of is accepted")
    func theBaselineEntryIsFine() throws {
        let found = try rows(["a": ["cwd": "/tmp/p", "pid": 999_999,
                                    "startedAt": 1_700_000_000_000,
                                    "updatedAt": 1_700_000_100_000]])
        #expect(found.count == 1)
        #expect(found.first?.startedAt != nil)
        #expect(found.first?.lastActivity != nil)
    }

    @Test("A null pid is absent, which is different from an unusable one")
    func nullPidIsAllowed() throws {
        let found = try rows(["a": ["cwd": "/tmp/p", "pid": NSNull()]])
        #expect(found.count == 1)
        #expect(found.first?.pid == nil)
    }

    @Test("More entries than the registry may hold is refused, not truncated")
    func tooManyEntries() throws {
        var entries: [String: [String: Any]] = [:]
        for i in 0..<513 { entries["s\(i)"] = ["cwd": "/tmp/p\(i)"] }
        #expect(throws: (any Swift.Error).self) { try rows(entries) }
    }

    /// A symlink is the case the regular-file check exists for. A directory
    /// is refused by the read that follows whether the check is there or not,
    /// so testing with one proves nothing about the check — the first version
    /// of this test did that, and removing the check left it passing.
    @Test("A symlink into the registry is refused rather than followed")
    func symlinkEntryIsRefused() throws {
        let root = try registry(["a": ["cwd": "/tmp/p"]])
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["cwd": "/tmp/elsewhere"])
            .write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("b.json"), withDestinationURL: outside)
        #expect(throws: (any Swift.Error).self) {
            try AgentScan.claudeRows(try descriptor(at: root), processes: [:])
        }
    }

    @Test("Files that are not session records are ignored")
    func nonJSONIsIgnored() throws {
        let root = try registry(["a": ["cwd": "/tmp/p"]])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a session".utf8).write(to: root.appendingPathComponent("README.txt"))
        let found = try AgentScan.claudeRows(try descriptor(at: root), processes: [:])
        #expect(found.count == 1)
    }
}
