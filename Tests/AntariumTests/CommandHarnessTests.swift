import Foundation
import Testing
@testable import Antarium

/// The reader behind herdr and orca: a command is run and its JSON becomes
/// sessions. It is the only reader whose input arrives from a process this
/// app starts, and it had the least coverage of the four.
@Suite("A command harness reads bounded, private output", .serialized)
struct CommandHarnessTests {

    /// A script standing in for the workspace manager, so none of this needs
    /// one installed.
    private func harness(printing script: String, root: String? = nil,
                         refreshEvery: Int? = nil, exit code: Int = 0) throws
        -> (HarnessDescriptor, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tool = dir.appendingPathComponent("tool")
        try Data("#!/bin/sh\n\(script)\nexit \(code)\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: tool.path)
        var source: [String: Any] = ["kind": "command", "path": "", "command": tool.path]
        if let root { source["root"] = root }
        if let refreshEvery { source["refreshEvery"] = refreshEvery }
        let object: [String: Any] = [
            "formatVersion": 1, "id": "cmd-\(UUID().uuidString)", "name": "Fixture",
            "process": [:], "source": source, "map": ["cwd": "cwd", "title": "title"]]
        return (try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor, dir)
    }

    private func sessions(_ descriptor: HarnessDescriptor) -> [HarnessEngine.Session] {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        HarnessEngine.resetCaches()
        return HarnessEngine.sessions(descriptor)
    }

    @Test("Records are read out of the declared root")
    func declaredRoot() throws {
        let (descriptor, dir) = try harness(
            printing: #"echo '{"result":{"agents":[{"cwd":"/a"},{"cwd":"/b"}]}}'"#,
            root: "result.agents")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(sessions(descriptor).count == 2)
    }

    @Test("A bare array with no declared root is read as it stands")
    func bareArray() throws {
        let (descriptor, dir) = try harness(printing: #"echo '[{"cwd":"/a"}]'"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(sessions(descriptor).count == 1)
    }

    /// The reason the failure message is fixed text. A command's stdout can
    /// carry titles, paths and tokens, and a diagnostic is somewhere it must
    /// not end up.
    @Test("A failing command's output does not reach its failure message")
    func outputStaysPrivate() throws {
        let secret = "synthetic-private-marker"
        let (descriptor, dir) = try harness(printing: "echo '\(secret)'", exit: 3)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(sessions(descriptor).isEmpty)
        let health = try #require(HarnessEngine.health(for: descriptor.id))
        #expect(!"\(health)".contains(secret),
                "the command's own output was put into a diagnostic")
    }

    @Test("A command that prints no JSON reports that, and nothing else")
    func nonJSONOutput() throws {
        let (descriptor, dir) = try harness(printing: "echo 'not json at all'")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(sessions(descriptor).isEmpty)
        let health = try #require(HarnessEngine.health(for: descriptor.id))
        #expect(!"\(health)".contains("not json at all"))
    }

    /// A workspace manager is polled while the bar is open, so its refresh
    /// interval is the difference between one subprocess every few seconds
    /// and one on every scan.
    @Test("The declared refresh interval is honoured between readings")
    func refreshIntervalIsHonoured() throws {
        let (descriptor, dir) = try harness(
            printing: #"echo '[{"cwd":"/a"}]' >> "$0.runs"; echo '[{"cwd":"/a"}]'"#,
            refreshEvery: 3_600)
        defer { try? FileManager.default.removeItem(at: dir) }
        HarnessEngineTestIsolation.lock.lock()
        HarnessEngine.resetCaches()
        _ = HarnessEngine.sessions(descriptor)
        _ = HarnessEngine.sessions(descriptor)
        _ = HarnessEngine.sessions(descriptor)
        HarnessEngineTestIsolation.lock.unlock()
        let runs = dir.appendingPathComponent("tool.runs")
        let count = (try? String(contentsOf: runs, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        #expect(count == 1, "the command ran \(count) times inside its refresh window")
    }

    @Test("A command reporting thousands of sessions yields a bounded number")
    func boundedSessions() throws {
        let (descriptor, dir) = try harness(
            printing: #"python3 -c 'import json;print(json.dumps([{"cwd":"/p%d"%i} for i in range(5000)]))'"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(sessions(descriptor).count == HarnessEngine.maxCommandSessions)
    }

    @Test("An ordinary reply is not truncated by that bound")
    func ordinaryReplyIsWhole() throws {
        let (descriptor, dir) = try harness(
            printing: #"echo '[{"cwd":"/a"},{"cwd":"/b"},{"cwd":"/c"}]'"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(sessions(descriptor).count == 3)
    }
}
