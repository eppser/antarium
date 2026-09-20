import Foundation
import SQLite3

/// Evidence-backed compatibility checks for bundled and third-party harnesses.
/// A declaration in JSON never upgrades itself: `fixtureVerified` is reported
/// only when the fixture executes through the real engine and exact expected
/// values match.
enum HarnessCompatibility {
    nonisolated(unsafe) private static var cachedReports: [String: Report] = [:]
    private static let cacheLock = NSLock()
    enum Status: String, Codable {
        case experimental, declared, fixtureVerified, liveAvailable, incompatible
    }

    struct Snapshot: Codable, Equatable {
        var sessions: Int
        var sessionID: String?
        var cwd: String?
        var title: String?
        var model: String?
        var inputTokens: Int
        var outputTokens: Int
        var cacheRead: Int
        var cacheWrite: Int
        var contextTokens: Int
        var contextWindow: Int?
        var toolCalls: Int
        var turns: Int
        var subAgents: Int
        var costUSD: Double

        static func capture(_ sessions: [HarnessEngine.Session]) -> Snapshot {
            let first = sessions.first
            return Snapshot(sessions: sessions.count,
                            sessionID: first?.sessionID,
                            cwd: first?.cwd,
                            title: first?.title,
                            model: first?.model,
                            inputTokens: first?.inputTokens ?? 0,
                            outputTokens: first?.outputTokens ?? 0,
                            cacheRead: first?.cacheRead ?? 0,
                            cacheWrite: first?.cacheWrite ?? 0,
                            contextTokens: first?.contextTokens ?? 0,
                            contextWindow: first?.contextWindow,
                            toolCalls: first?.toolCalls ?? 0,
                            turns: first?.turns ?? 0,
                            subAgents: first?.subAgents ?? 0,
                            costUSD: first?.costUSD ?? 0)
        }
    }

    struct Report {
        let status: Status
        let detail: String
        let verifiedAt: String?
        let expected: Snapshot?
        let actual: Snapshot?
    }

    private struct Fixture: Codable {
        var files: [String: String]?
        var setupSQL: String?
        let expected: Snapshot
    }

    static func verifyFixture(_ descriptor: HarnessDescriptor, in bundle: Bundle) -> Report {
        let fixtureStamp = descriptor.compatibility?.fixture
            .flatMap { resource($0, in: bundle) }
            .map(FileStamp.of) ?? ""
        let encoded = (try? JSONEncoder().encode(descriptor)).map { Data($0).base64EncodedString() }
            ?? descriptor.id
        let key = "\(encoded)|\(fixtureStamp)"
        cacheLock.lock()
        if let report = cachedReports[key] {
            cacheLock.unlock()
            return report
        }
        cacheLock.unlock()
        let report = verifyFixtureUncached(descriptor, in: bundle)
        cacheLock.lock()
        cachedReports[key] = report
        cacheLock.unlock()
        return report
    }

    private static func verifyFixtureUncached(_ descriptor: HarnessDescriptor,
                                              in bundle: Bundle) -> Report {
        guard let declaration = descriptor.compatibility else {
            return Report(status: .experimental, detail: "no compatibility evidence declared",
                          verifiedAt: nil, expected: nil, actual: nil)
        }
        guard let fixturePath = declaration.fixture, !fixturePath.isEmpty else {
            return Report(status: declaration.level == .experimental ? .experimental : .declared,
                          detail: "no executable fixture declared",
                          verifiedAt: declaration.verifiedAt, expected: nil, actual: nil)
        }
        guard let fixtureURL = resource(fixturePath, in: bundle),
              let data = try? Data(contentsOf: fixtureURL),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            return Report(status: .incompatible, detail: "fixture missing or unreadable: \(fixturePath)",
                          verifiedAt: declaration.verifiedAt, expected: nil, actual: nil)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antarium-fixture-\(descriptor.id)-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for (relative, contents) in fixture.files ?? [:] {
                let file = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: file, options: .atomic)
            }

            var object = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(descriptor)) as? [String: Any] ?? [:]
            var source = object["source"] as? [String: Any] ?? [:]
            if descriptor.source.kind == .command {
                // A command harness reads a tool's live output. Replaying it
                // means running that tool, which needs it installed — and the
                // whole point of a fixture is that nothing has to be. The
                // command is replaced with one that prints the recorded reply,
                // so the mapping, the records path and the field paths are all
                // exercised exactly as they would be against the real thing.
                guard let name = (fixture.files ?? [:]).keys.sorted().first else {
                    throw FixtureError.sqlite("a command fixture needs a recorded reply in `files`")
                }
                source["command"] = "/bin/cat"
                source["args"] = [root.appendingPathComponent(name).path]
            } else if descriptor.source.kind == .sqlite {
                let databaseURL = root.appendingPathComponent("fixture.sqlite")
                var database: OpaquePointer?
                guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
                      let database else { throw FixtureError.sqlite("open failed") }
                defer { sqlite3_close(database) }
                if let sql = fixture.setupSQL {
                    var message: UnsafeMutablePointer<CChar>?
                    let code = sqlite3_exec(database, sql, nil, nil, &message)
                    let detail = message.map { String(cString: $0) }
                    sqlite3_free(message)
                    guard code == SQLITE_OK else {
                        throw FixtureError.sqlite(detail ?? "setup failed")
                    }
                }
                source["path"] = databaseURL.path
            } else {
                source["path"] = root.path
            }
            object["source"] = source
            object["id"] = "\(descriptor.id)-fixture-\(UUID().uuidString)"
            let configured = try HarnessDocument.decode(
                JSONSerialization.data(withJSONObject: object)).descriptor
            HarnessEngine.resetCaches(includingParsedFiles: true)
            let actual = Snapshot.capture(HarnessEngine.sessions(configured))
            let passed = actual == fixture.expected
            return Report(status: passed ? .fixtureVerified : .incompatible,
                          detail: passed ? "fixture passed" : "fixture values differ",
                          verifiedAt: declaration.verifiedAt,
                          expected: fixture.expected, actual: actual)
        } catch {
            return Report(status: .incompatible,
                          detail: "fixture failed: \(error.localizedDescription)",
                          verifiedAt: declaration.verifiedAt,
                          expected: fixture.expected, actual: nil)
        }
    }

    /// Runtime evidence is deliberately separate from fixture evidence. A
    /// source existing locally says it can be inspected; it does not claim its
    /// field mappings are correct until `--check` observes them.
    static func sourceIsAvailable(_ descriptor: HarnessDescriptor) -> Bool {
        switch descriptor.source.kind {
        case .none: return false
        case .command:
            guard let command = descriptor.source.command else { return false }
            return command.contains("/")
                ? FileManager.default.isExecutableFile(atPath: command.expandingTilde)
                : true
        case .sqlite:
            return FileManager.default.fileExists(atPath: descriptor.source.path.expandingTilde)
        case .json, .jsonl:
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: descriptor.source.path.expandingTilde,
                                                  isDirectory: &directory) && directory.boolValue
        }
    }

    private static func resource(_ path: String, in bundle: Bundle) -> URL? {
        let value = path as NSString
        let directory = value.deletingLastPathComponent
        let name = value.lastPathComponent as NSString
        return bundle.url(forResource: name.deletingPathExtension,
                          withExtension: name.pathExtension,
                          subdirectory: directory.isEmpty ? nil : directory)
    }

    private enum FixtureError: Swift.Error, LocalizedError {
        case sqlite(String)
        var errorDescription: String? {
            if case .sqlite(let message) = self { return "SQLite fixture \(message)" }
            return nil
        }
    }
}
