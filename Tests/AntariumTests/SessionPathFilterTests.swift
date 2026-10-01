import Foundation
import Testing
@testable import Antarium

/// The session-reading half of the same vocabulary.
///
/// Field paths in the `map` block already resolve brackets — VS Code's
/// `v.requests[].promptTokens` is how a session's tokens are summed — because
/// the token, timestamp and context fields go through `FieldPath.each`. Three
/// fields did not: `map.pid`, `map.turns.path`, and `source.root`, which read a
/// single value through a flat lookup. So one block accepted two different
/// notations depending on which field you wrote it in, and nothing said which.
///
/// Same for the session-selection block: `records` and `root` are documented as
/// paths to an array and the `filter` keys as fields every record must match.
///
/// These are the last of the flat lookups over descriptor-declared paths. What
/// remains is deliberate: a capability's `keys` are object or *TOML* key names,
/// and a credential's `path` is a filesystem path.
@Suite("Every session-surface path resolves a filter written in it", .serialized)
struct SessionPathFilterTests {

    /// A harness over one temporary JSONL file, with whatever `map` the case
    /// needs. Written and removed inside the body, as every fixture here is.
    private func session(record: [String: Any], map: [String: Any]) throws
        -> HarnessEngine.Session? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-path-\(UUID().uuidString)")
        let project = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: record),
                          as: UTF8.self) + "\n"
        try Data(line.utf8).write(to: project.appendingPathComponent("session.jsonl"))
        let document: [String: Any] = [
            "formatVersion": 1, "id": "session-path", "name": "Session path",
            "process": [:],
            "source": ["kind": "jsonl", "path": root.path, "glob": "*/*.jsonl"],
            "map": map,
        ]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: document)).descriptor
        HarnessEngine.resetCaches()
        return HarnessEngine.sessions(descriptor).first
    }

    /// `map.pid`. The decoy carries a pid that must not be adopted, so reading
    /// the path flatly finds nothing and reading it loosely finds the wrong one.
    @Test("A filtered pid path reads the process it names")
    func filteredPid() throws {
        let record: [String: Any] = [
            "timestamp": "2026-09-26T12:00:00Z",
            "processes": [["role": "helper", "pid": 4321], ["role": "main", "pid": 1234]],
        ]
        let session = try #require(try session(
            record: record,
            map: ["timestamp": "timestamp", "pid": "processes[role=main].pid"]))
        #expect(session.pid == 1234,
                Comment(rawValue: "a filtered pid path read \(session.pid.map(String.init) ?? "nothing")"))
    }

    /// And a filter naming no process leaves the pid unread rather than taking
    /// whichever one happened to be first.
    @Test("A pid filter matching nothing leaves the pid unread")
    func pidFilterMatchingNothing() throws {
        let record: [String: Any] = [
            "timestamp": "2026-09-26T12:00:00Z",
            "processes": [["role": "helper", "pid": 4321]],
        ]
        let session = try #require(try session(
            record: record,
            map: ["timestamp": "timestamp", "pid": "processes[role=main].pid"]))
        #expect(session.pid == nil)
    }

    /// A plain path still reads a pid, which is every shipped descriptor.
    @Test("A plain pid path is still the field it names")
    func plainPid() throws {
        let session = try #require(try session(
            record: ["timestamp": "2026-09-26T12:00:00Z", "pid": 99],
            map: ["timestamp": "timestamp", "pid": "pid"]))
        #expect(session.pid == 99)
    }

    /// `map.turns.path` — a count is present when the path names a collection,
    /// and a filter has to reach the collection rather than the array holding it.
    @Test("A filtered turn-count path finds the collection it names")
    func filteredTurnCount() throws {
        let record: [String: Any] = [
            "timestamp": "2026-09-26T12:00:00Z",
            "groups": [
                ["kind": "tools", "items": [["a": 1], ["a": 2], ["a": 3]]],
                ["kind": "turns", "items": [["t": 1], ["t": 2]]],
            ],
        ]
        let session = try #require(try session(record: record, map: [
            "timestamp": "timestamp",
            "turns": ["path": "groups[kind=turns].items"],
        ]))
        #expect(session.turns == 2,
                Comment(rawValue: "counted \(session.turns) turns"))
    }

    /// The same path written without the filter counts the wrong thing, which is
    /// what makes the assertion above about the filter rather than the count.
    @Test("Without the filter the same reply counts every group")
    func withoutTheFilter() throws {
        let record: [String: Any] = [
            "timestamp": "2026-09-26T12:00:00Z",
            "groups": [
                ["kind": "tools", "items": [["a": 1], ["a": 2], ["a": 3]]],
                ["kind": "turns", "items": [["t": 1], ["t": 2]]],
            ],
        ]
        let session = try #require(try session(record: record, map: [
            "timestamp": "timestamp", "turns": ["path": "groups"],
        ]))
        #expect(session.turns == 2, "the outer array has two entries, not the turns' two")
    }
}

/// `selection.records`, `selection.root`, and the `filter` keys.
///
/// Driven through `SessionSelection.openIDs`, the entry point every other
/// selection test uses, rather than by reaching into the private decision — so
/// the path is resolved by the code the app runs.
@Suite("A selection path resolves a filter written in it", .serialized)
struct RecordsPathFilterTests {

    private func openIDs(_ selection: String) throws -> Set<String>? {
        let data = Data("""
        {
          "formatVersion":1,"id":"selection-path","name":"Selection path","process":{},
          "source":{"kind":"none","path":""},
          "selection":\(selection)
        }
        """.utf8)
        return SessionSelection.openIDs(try HarnessDocument.decode(data).descriptor.sessionSelection)
    }

    /// A shell command printing the reply, so the whole route — command,
    /// `root`, `id`, `filter` — is the one the app takes.
    private func printing(_ json: String) -> String {
        let escaped = json.replacingOccurrences(of: "\"", with: "\\\"")
        return #""kind":"command","command":"/bin/sh","args":["-c","printf '\#(escaped)'"]"#
    }

    /// `root` — the array of sessions reached by a filter on an envelope.
    @Test("A filtered selection root resolves to the array it names")
    func filteredRoot() throws {
        let reply = #"{"envelopes":[{"kind":"stale","rows":[{"id":"old","open":true}]},"#
            + #"{"kind":"live","rows":[{"id":"live","open":true}]}]}"#
        let ids = try openIDs("{" + printing(reply)
            + #","root":"envelopes[kind=live].rows","id":"id","filter":{"open":["true"]}}"#)
        #expect(ids == ["live"], "a filtered selection root read the wrong envelope")
    }

    /// A filter key is a field every record must match, and a filtered one has
    /// to reach the entry it names rather than any that holds the value.
    @Test("A filtered selection key checks the entry it names")
    func filteredSelectionKey() throws {
        let reply = #"[{"id":"wanted","tags":[{"k":"app","v":"cli"},{"k":"other","v":"desktop"}]},"#
            + #"{"id":"skipped","tags":[{"k":"app","v":"desktop"},{"k":"other","v":"cli"}]}]"#
        let ids = try openIDs("{" + printing(reply)
            + #","id":"id","filter":{"tags[k=app].v":["cli"]}}"#)
        #expect(ids == ["wanted"], "a filtered selection key matched on the wrong tag")
    }

    /// A key matching no entry keeps nothing, which is the direction that
    /// matters: a harness whose sessions look like another's must not adopt them.
    @Test("A selection key matching no entry keeps nothing")
    func selectionKeyMatchingNothing() throws {
        let reply = #"[{"id":"wanted","tags":[{"k":"other","v":"cli"}]}]"#
        #expect(try openIDs("{" + printing(reply)
            + #","id":"id","filter":{"tags[k=app].v":["cli"]}}"#) == [])
    }

    /// A plain key still works, which is every shipped descriptor.
    @Test("A plain selection key is still the field it names")
    func plainSelectionKey() throws {
        let reply = #"[{"id":"a","app":"cli"},{"id":"b","app":"desktop"}]"#
        #expect(try openIDs("{" + printing(reply) + #","id":"id","filter":{"app":["cli"]}}"#)
                == ["a"])
    }

    /// And a plain root still resolves, which is the shape that predates this.
    @Test("A plain selection root is still the array it names")
    func plainRoot() throws {
        let reply = #"{"rows":[{"id":"a","open":true},{"id":"b","open":false}]}"#
        #expect(try openIDs("{" + printing(reply)
            + #","root":"rows","id":"id","filter":{"open":["true"]}}"#) == ["a"])
    }
}

/// The two routes the suites above do not reach: a `jsonFiles` selection, which
/// reads its records from files rather than a command, and a `command` source,
/// whose `root` is a separate call site from the file source's.
///
/// Both surfaced as surviving mutations. The path resolution is the same line of
/// reasoning in each, and that is exactly why they needed their own cases:
/// "the same change, elsewhere" is how a second copy goes unnoticed.
@Suite("The other two routes resolve a filter too", .serialized)
struct OtherRoutePathFilterTests {

    /// A `jsonFiles` selection over one temporary state file.
    @Test("A filtered selection records path reads the array it names")
    func filteredRecordsPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("records-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = #"""
        {"envelopes":[{"kind":"stale","rows":[{"id":"old","open":true}]},
                      {"kind":"live","rows":[{"id":"live","open":true}]}]}
        """#
        try Data(state.utf8).write(to: root.appendingPathComponent("state.json"))

        let data = Data("""
        {
          "formatVersion":1,"id":"records-path","name":"Records path","process":{},
          "source":{"kind":"none","path":""},
          "selection":{"kind":"jsonFiles","path":"\(root.path)","glob":"*.json",
            "records":"envelopes[kind=live].rows","id":"id","filter":{"open":["true"]}}
        }
        """.utf8)
        let ids = SessionSelection.openIDs(try HarnessDocument.decode(data).descriptor.sessionSelection)
        #expect(ids == ["live"], "a filtered records path read the wrong envelope")
    }

    /// And a plain records path still resolves, which is the shape that predates
    /// the filter.
    @Test("A plain selection records path is still the array it names")
    func plainRecordsPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("records-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"rows":[{"id":"a","open":true},{"id":"b","open":false}]}"#.utf8)
            .write(to: root.appendingPathComponent("state.json"))
        let data = Data("""
        {
          "formatVersion":1,"id":"records-plain","name":"Records plain","process":{},
          "source":{"kind":"none","path":""},
          "selection":{"kind":"jsonFiles","path":"\(root.path)","glob":"*.json",
            "records":"rows","id":"id","filter":{"open":["true"]}}
        }
        """.utf8)
        #expect(SessionSelection.openIDs(
            try HarnessDocument.decode(data).descriptor.sessionSelection) == ["a"])
    }

    /// A `command` source, whose `root` is read at its own call site.
    @Test("A filtered command source root reads the array it names")
    func filteredCommandSourceRoot() throws {
        let reply = #"{\"envelopes\":[{\"kind\":\"stale\",\"rows\":[{\"id\":\"old\",\"cwd\":\"/synthetic/old\",\"time\":\"2020-01-01T00:00:00Z\"}]},"#
            + #"{\"kind\":\"live\",\"rows\":[{\"id\":\"live\",\"cwd\":\"/synthetic/live\",\"time\":\"2026-09-26T12:00:00Z\"}]}]}"#
        let data = Data("""
        {
          "formatVersion":1,"id":"cmd-root","name":"Command root","process":{},
          "source":{"kind":"command","path":"","command":"/bin/sh",
            "args":["-c","printf '\(reply)'"],
            "root":"envelopes[kind=live].rows"},
          "map":{"id":"id","cwd":"cwd","timestamp":"time"}
        }
        """.utf8)
        let descriptor = try HarnessDocument.decode(data).descriptor
        HarnessEngine.resetCaches()
        let sessions = HarnessEngine.sessions(descriptor)
        #expect(sessions.count == 1,
                Comment(rawValue: "read \(sessions.count) sessions, so the root resolved wrongly"))
        #expect(sessions.first?.cwd == "/synthetic/live",
                "a filtered command source root read the wrong envelope")
    }

    /// And a plain root over the same route.
    @Test("A plain command source root is still the array it names")
    func plainCommandSourceRoot() throws {
        let reply = #"{\"rows\":[{\"id\":\"one\",\"cwd\":\"/synthetic/one\",\"time\":\"2026-09-26T12:00:00Z\"}]}"#
        let data = Data("""
        {
          "formatVersion":1,"id":"cmd-root-plain","name":"Command root plain","process":{},
          "source":{"kind":"command","path":"","command":"/bin/sh",
            "args":["-c","printf '\(reply)'"],"root":"rows"},
          "map":{"id":"id","cwd":"cwd","timestamp":"time"}
        }
        """.utf8)
        HarnessEngine.resetCaches()
        let sessions = HarnessEngine.sessions(try HarnessDocument.decode(data).descriptor)
        #expect(sessions.first?.cwd == "/synthetic/one")
    }
}
