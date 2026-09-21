import Foundation
import Testing
@testable import Antarium

@Suite("Registry transcript path boundaries")
struct RegistryPathBoundaryTests {
    private func fixture(_ body:(URL,URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-fixture-\(UUID())")
        let project = root.appendingPathComponent("-fixture-project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try body(root,project)
    }
    @Test("A session identifier cannot traverse out of its declared project directory")
    func traversal() throws {
        try fixture { root, _ in
            try Data("{}\n".utf8).write(to:root.appendingPathComponent("outside.jsonl"))
            #expect(AgentScan.transcriptURL(cwd:"/fixture/project",sessionID:"../outside",root:root.path) == nil)
        }
    }
    @Test("Linked transcripts are unavailable instead of binding outside the trace source")
    func symlink() throws {
        try fixture { root, project in
            let target = root.appendingPathComponent("outside.jsonl")
            try Data("{}\n".utf8).write(to:target)
            try FileManager.default.createSymbolicLink(at:project.appendingPathComponent("session.jsonl"),withDestinationURL:target)
            #expect(AgentScan.transcriptURL(cwd:"/fixture/project",sessionID:"session",root:root.path) == nil)
        }
    }
    @Test("Exact and resumed-session matches still resolve regular bounded sources")
    func valid() throws {
        try fixture { root, project in
            let file = project.appendingPathComponent("first.jsonl")
            try Data(#"{"sessionId":"resumed"}"#.utf8).write(to:file)
            #expect(AgentScan.transcriptURL(cwd:"/fixture/project",sessionID:"first",root:root.path) == file)
            #expect(AgentScan.transcriptURL(cwd:"/fixture/project",sessionID:"resumed",root:root.path)?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        }
    }
    @Test("A quoted example of another session ID is not a resumed-session binding")
    func embeddedID() throws {
        try fixture { root, project in
            let object:[String:Any] = ["sessionId":"actual","message":["sessionId":"unrelated"]]
            try JSONSerialization.data(withJSONObject:object,options:.sortedKeys).write(to:project.appendingPathComponent("first.jsonl"))
            #expect(AgentScan.transcriptURL(cwd:"/fixture/project",sessionID:"unrelated",root:root.path) == nil)
        }
    }
}

/// Finding the transcript a resumed session is actually writing to. The
/// boundaries — traversal, control characters, links — are covered above;
/// which file it picks when several could match was not, and picking the
/// wrong one puts another session's figures on the row.
@Suite("Resumed transcript resolution", .serialized)
struct ResumedTranscriptTests {

    private let cwd = "/synthetic/project"

    /// Files are written oldest first and stamped explicitly, so the ordering
    /// under test is the one being asserted rather than whatever the
    /// filesystem happened to record.
    private func project(_ files: [(name: String, sessionID: String?, age: TimeInterval)])
        throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            let url = dir.appendingPathComponent(file.name)
            let line = file.sessionID.map { #"{"sessionId":"\#($0)","x":1}"# + "\n" } ?? "{}\n"
            try Data(line.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-file.age)], ofItemAtPath: url.path)
        }
        return root
    }

    @Test("A transcript named for the session is used directly")
    func exactMatch() throws {
        let root = try project([("wanted.jsonl", nil, 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = AgentScan.transcriptURL(cwd: cwd, sessionID: "wanted", root: root.path)
        #expect(found?.lastPathComponent == "wanted.jsonl")
    }

    /// Claude keeps the original id as the filename across a resume, so the
    /// id has to be found inside. Several files can carry it, and the one
    /// being written to now is the newest — an older one holds the figures
    /// from a session that has already finished.
    @Test("When several transcripts name the session, the newest wins")
    func newestWins() throws {
        let root = try project([
            ("old.jsonl", "shared", 3_600),
            ("newer.jsonl", "shared", 60),
            ("oldest.jsonl", "shared", 86_400),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = AgentScan.transcriptURL(cwd: cwd, sessionID: "shared", root: root.path)
        #expect(found?.lastPathComponent == "newer.jsonl")
    }

    /// The search reads and parses each candidate, so it stops after the few
    /// newest. A project with a long history must not cost a scan.
    @Test("Only the newest few transcripts are searched")
    func searchIsBounded() throws {
        var files: [(String, String?, TimeInterval)] = []
        for i in 0..<20 { files.append(("decoy-\(i).jsonl", "other", TimeInterval(i * 60))) }
        // The one that names the session is older than the eight newest.
        files.append(("wanted.jsonl", "shared", 86_400))
        let root = try project(files.map { (name: $0.0, sessionID: $0.1, age: $0.2) })
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentScan.transcriptURL(cwd: cwd, sessionID: "shared", root: root.path) == nil,
                "the search went further back than its bound")
    }

    @Test("A file that is not a transcript is not searched")
    func onlyTranscripts() throws {
        let root = try project([("notes.txt", "shared", 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentScan.transcriptURL(cwd: cwd, sessionID: "shared", root: root.path) == nil)
    }

    @Test("A project with no matching transcript resolves to nothing")
    func noMatch() throws {
        let root = try project([("other.jsonl", "different", 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentScan.transcriptURL(cwd: cwd, sessionID: "shared", root: root.path) == nil)
    }
}
