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
