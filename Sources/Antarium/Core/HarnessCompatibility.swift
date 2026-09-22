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
        /// Every field that differs, named, so an author is told what to fix
        /// rather than handed two structures to compare by eye.
        ///
        /// Driven from the encoded form rather than a written-out list of
        /// properties: a field added to this struct and forgotten here would
        /// be a difference that reports itself as no difference at all.
        static func differences(expected: Snapshot, actual: Snapshot) -> [String] {
            func fields(_ value: Snapshot) -> [String: Any] {
                (try? JSONEncoder().encode(value))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                    as? [String: Any] ?? [:]
            }
            let left = fields(expected), right = fields(actual)
            return Set(left.keys).union(right.keys).sorted().compactMap { key in
                let want = left[key], got = right[key]
                func text(_ value: Any?) -> String {
                    guard let value, !(value is NSNull) else { return "absent" }
                    return String(describing: value)
                }
                return text(want) == text(got) ? nil : "\(key) \(text(got)) ≠ \(text(want))"
            }
        }

        var sessions: Int
        var sessionID: String?
        /// What a click would use to raise this session. Absent for a harness
        /// that does not own its windows; verified for the ones that do,
        /// because a focus mapping that resolves to nothing fails silently —
        /// the row simply falls back to raising the application, and looks
        /// like it worked.
        var focusTarget: String?
        var cwd: String?
        var title: String?
        var model: String?
        var inputTokens: Int
        var outputTokens: Int
        var cacheRead: Int
        var cacheWrite: Int
        var contextTokens: Int?
        var contextWindow: Int?
        var toolCalls: Int
        var turns: Int
        var subAgents: Int
        var costUSD: Double

        static func capture(_ sessions: [HarnessEngine.Session]) -> Snapshot {
            let first = sessions.first
            return Snapshot(sessions: sessions.count,
                            sessionID: first?.sessionID,
                            focusTarget: first?.focusTarget,
                            cwd: first?.cwd,
                            title: first?.title,
                            model: first?.model,
                            inputTokens: first?.inputTokens ?? 0,
                            outputTokens: first?.outputTokens ?? 0,
                            cacheRead: first?.cacheRead ?? 0,
                            cacheWrite: first?.cacheWrite ?? 0,
                            contextTokens: first?.contextTokens ?? nil,
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

    /// `beside` is the folder the descriptor itself was read from, for a
    /// harness that is not in the app. A fixture declared by somebody's own
    /// descriptor lives next to it; looking only in the bundle meant the
    /// declaration could not be honoured or questioned, so a file claiming
    /// `fixtureVerified` with its fixture sitting right there was checked
    /// against nothing.
    static func verifyFixture(_ descriptor: HarnessDescriptor, in bundle: Bundle,
                              beside: URL? = nil) -> Report {
        let fixtureStamp = descriptor.compatibility?.fixture
            .flatMap { resource($0, in: bundle, beside: beside) }
            .map(FileStamp.of) ?? ""
        let encoded = (try? JSONEncoder().encode(descriptor)).map { Data($0).base64EncodedString() }
            ?? descriptor.id
        // The folder is part of the key: the same descriptor read from two
        // places can resolve to two different fixtures.
        let key = "\(encoded)|\(fixtureStamp)|\(beside?.path ?? "")"
        cacheLock.lock()
        if let report = cachedReports[key] {
            cacheLock.unlock()
            return report
        }
        cacheLock.unlock()
        let report = verifyFixtureUncached(descriptor, in: bundle, beside: beside)
        cacheLock.lock()
        cachedReports[key] = report
        cacheLock.unlock()
        return report
    }

    private static func verifyFixtureUncached(_ descriptor: HarnessDescriptor,
                                              in bundle: Bundle,
                                              beside: URL? = nil) -> Report {
        guard let declaration = descriptor.compatibility else {
            return Report(status: .experimental, detail: "no compatibility evidence declared",
                          verifiedAt: nil, expected: nil, actual: nil)
        }
        guard let fixturePath = declaration.fixture, !fixturePath.isEmpty else {
            return Report(status: declaration.level == .experimental ? .experimental : .declared,
                          detail: "no executable fixture declared",
                          verifiedAt: declaration.verifiedAt, expected: nil, actual: nil)
        }
        guard let fixtureURL = resource(fixturePath, in: bundle, beside: beside),
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
            // No cache reset here. It cleared every harness's sessions and
            // every parsed file, and the settings panel verifies one fixture
            // per harness row — so opening Settings emptied the scan cache
            // once per row and made the next scan cold, on a machine with
            // twenty-five of them.
            //
            // It was standing in for a collision that cannot happen. The
            // engine keys its cache by descriptor id, and the fixture run
            // uses the id of the harness it is checking, which looks like
            // exactly that collision — but the entry is guarded by a
            // fingerprint that includes the descriptor, and the fixture run
            // rewrites `source.path` to a temporary tree of its own. The
            // fingerprints differ, so the real entry is never returned here
            // and nothing written here is ever returned to a real scan. A
            // test holds that directly now.
            let actual = Snapshot.capture(HarnessEngine.sessions(configured))
            let passed = actual == fixture.expected
            // Which fields differ, not merely that some do. "fixture values
            // differ" sends an author to compare two structures by eye; the
            // quota verifier beside this one has always named them, and the
            // information was already here in `expected` and `actual`.
            let detail = passed ? "fixture passed"
                : "fixture values differ: "
                    + Snapshot.differences(expected: fixture.expected, actual: actual)
                        .joined(separator: "; ")
            return Report(status: passed ? .fixtureVerified : .incompatible,
                          detail: detail,
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
            // A bare name is taken on trust here: this asks whether the source
            // *can* be inspected, and `--check` is what confirms it.
            return command.contains("/")
                ? CommandPath.resolve(command) != nil
                : true
        case .sqlite:
            return FileManager.default.fileExists(atPath: descriptor.source.path.expandingTilde)
        case .json, .jsonl:
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: descriptor.source.path.expandingTilde,
                                                  isDirectory: &directory) && directory.boolValue
        }
    }

    /// The bundle first, then the folder the descriptor came from.
    ///
    /// The bundle first so a shipped descriptor cannot be made to read a
    /// fixture from somewhere else by putting a file beside it, and the
    /// folder second so a harness that is not in the app can declare one at
    /// all. The name is taken as a name: a path that climbs out of that
    /// folder is not resolved, because a fixture is a file the author put
    /// next to their descriptor and nothing else.
    private static func resource(_ path: String, in bundle: Bundle,
                                 beside: URL? = nil) -> URL? {
        let value = path as NSString
        let directory = value.deletingLastPathComponent
        let name = value.lastPathComponent as NSString
        if let found = bundle.url(forResource: name.deletingPathExtension,
                                  withExtension: name.pathExtension,
                                  subdirectory: directory.isEmpty ? nil : directory) {
            return found
        }
        // Neither of these can change an answer, and both are written out
        // anyway. The name above is already only the last component, so a
        // declared path cannot climb out of the folder however it is spelled
        // — and a candidate that does not exist fails to read a line later
        // and is reported as missing either way. They state the rule where
        // somebody changing `name` would have to read it, and have no
        // catalogue entries, because a mutation of either survives.
        guard let beside, !path.contains(".."), !path.hasPrefix("/") else { return nil }
        let candidate = beside.appendingPathComponent(name as String)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private enum FixtureError: Swift.Error, LocalizedError {
        case sqlite(String)
        var errorDescription: String? {
            if case .sqlite(let message) = self { return "SQLite fixture \(message)" }
            return nil
        }
    }
}
