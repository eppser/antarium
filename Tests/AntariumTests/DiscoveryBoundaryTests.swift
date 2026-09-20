import Foundation
import Testing
@testable import Antarium

@Suite("Directory and session selection boundaries", .serialized)
struct DiscoveryBoundaryTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func descriptor(_ root:URL, glob:String) throws -> HarnessDescriptor {
        let object:[String:Any] = ["formatVersion":1,"id":"discovery-fixture","name":"Fixture","process":[:],
            "source":["kind":"json","path":root.path,"glob":glob],"map":["sessionId":"id","cwd":"cwd"]]
        return try HarnessDocument.decode(JSONSerialization.data(withJSONObject:object)).descriptor
    }
    private func selection(_ root:URL) -> HarnessDescriptor.Selection {
        .init(kind:.jsonFiles,path:root.path,glob:"window-*.json",records:"tabs",id:"sessionId",filter:["type":["session"]])
    }
    @Test("Recursive globs include zero-depth and deeply nested matching files")
    func recursiveGlob() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        try fixture { root in
            for (index,path) in ["top.json","one/middle.json","one/two/three/deep.json"].enumerated() {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
                try JSONSerialization.data(withJSONObject:["id":"session-\(index)","cwd":"/fixture"]).write(to:file)
            }
            HarnessEngine.resetCaches(includingParsedFiles:true)
            #expect(HarnessEngine.sessions(try descriptor(root,glob:"**/*.json")).count == 3)
        }
    }
    @Test("A wildcard within a filename matches both its prefix and suffix")
    func middleWildcard() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        try fixture { root in
            try Data(#"{"id":"one","cwd":"/fixture"}"#.utf8).write(to:root.appendingPathComponent("trace-one.json"))
            HarnessEngine.resetCaches(includingParsedFiles:true)
            #expect(HarnessEngine.sessions(try descriptor(root,glob:"trace-*.json")).count == 1)
        }
    }
    @Test("One corrupt window makes selection unavailable rather than hiding other open sessions")
    func partialSelection() throws {
        try fixture { root in
            try Data(#"{"tabs":[{"type":"session","sessionId":"one"}]}"#.utf8).write(to:root.appendingPathComponent("window-a.json"))
            try Data("corrupt".utf8).write(to:root.appendingPathComponent("window-b.json"))
            #expect(SessionSelection.openIDs(selection(root)) == nil)
        }
    }
    @Test("A matching tab without an ID is invalid, while no matching tabs is a real empty set")
    func missingID() throws {
        try fixture { root in
            let file = root.appendingPathComponent("window-a.json")
            try Data(#"{"tabs":[{"type":"session"}]}"#.utf8).write(to:file)
            #expect(SessionSelection.openIDs(selection(root)) == nil)
            try Data(#"{"tabs":[{"type":"settings"}]}"#.utf8).write(to:file)
            #expect(SessionSelection.openIDs(selection(root)) == [])
        }
    }
    @Test("Oversized state files and symlinks cannot contribute session selections")
    func boundedSelection() throws {
        try fixture { root in
            let target = root.appendingPathComponent("target.json")
            try Data(#"{"tabs":[{"type":"session","sessionId":"one"}]}"#.utf8).write(to:target)
            let file = root.appendingPathComponent("window-a.json")
            try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
            #expect(SessionSelection.openIDs(selection(root)) == nil)
            try FileManager.default.removeItem(at:file)
            let data = try JSONSerialization.data(withJSONObject:["padding":String(repeating:"x",count:4*1_024*1_024),"tabs":[]])
            try data.write(to:file)
            #expect(SessionSelection.openIDs(selection(root)) == nil)
        }
    }
    @Test("Legacy desktop selection also refuses incomplete window state")
    func legacySelection() throws {
        try fixture { root in
            try Data(#"{"tabs":[{"type":"session","sessionId":"one"}]}"#.utf8).write(to:root.appendingPathComponent("opencode.window.a.dat"))
            try Data("corrupt".utf8).write(to:root.appendingPathComponent("opencode.window.b.dat"))
            #expect(OpenCodeTabs.open(in:root) == nil)
        }
    }

    @Test("A corrected source clears its previous read failure")
    func recovery() throws {
        HarnessEngineTestIsolation.lock.lock(); defer { HarnessEngineTestIsolation.lock.unlock() }
        try fixture { root in
            let file = root.appendingPathComponent("session.json")
            let config = try descriptor(root,glob:"*.json")
            HarnessEngine.resetCaches(includingParsedFiles:true)
            try Data("invalid".utf8).write(to:file)
            #expect(HarnessEngine.sessions(config).isEmpty)
            #expect(HarnessEngine.health(for:config.id) != nil)
            try Data(#"{"id":"one","cwd":"/fixture"}"#.utf8).write(to:file)
            #expect(HarnessEngine.sessions(config).count == 1)
            #expect(HarnessEngine.health(for:config.id) == nil)
        }
    }

    @Test("Directory limits fail explicitly and recursive discovery never follows links")
    func directoryBudgets() throws {
        try fixture { root in
            let child = root.appendingPathComponent("child")
            try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
            try Data("{}".utf8).write(to:child.appendingPathComponent("one.json"))
            try Data("{}".utf8).write(to:root.appendingPathComponent("two.json"))
            try FileManager.default.createSymbolicLink(at:child.appendingPathComponent("loop"),withDestinationURL:root)
            #expect(try BoundedGlob.files(under:root,pattern:"**/*.json").count == 2)
            #expect(throws:(any Error).self) { try BoundedDirectory.entries(root,limit:1) }
            #expect(throws:(any Error).self) { try BoundedGlob.files(under:root,pattern:"**/*.json",maximumEntries:2) }
            #expect(throws:(any Error).self) { try BoundedGlob.files(under:root,pattern:"**/*.json",maximumDirectories:1) }
            #expect(throws:(any Error).self) { try BoundedGlob.files(under:root,pattern:"../*.json") }
            #expect(try BoundedGlob.files(under:root,pattern:"missing*.json").isEmpty)
        }
    }

    @Test("Path matching handles repeated recursive segments without exponential work")
    func matchingBounds() {
        #expect(BoundedGlob.matches(path:["one","two","session-a.json"],pattern:"**/session-*.json"))
        #expect(BoundedGlob.matches(path:["session-a.json"],pattern:"**/session-*.json"))
        #expect(!BoundedGlob.matches(path:["one","session-a.txt"],pattern:"**/session-*.json"))
        let began = ProcessInfo.processInfo.systemUptime
        #expect(!BoundedGlob.matches(path:Array(repeating:"a",count:100),pattern:String(repeating:"**/",count:60)+"missing"))
        #expect(ProcessInfo.processInfo.systemUptime - began < 0.1)
    }

    @Test("Selection work is bounded across all matching window files")
    func selectionFileCount() throws {
        try fixture { root in
            for index in 0..<65 {
                try Data(#"{"tabs":[]}"#.utf8).write(to:root.appendingPathComponent("window-\(index).json"))
            }
            #expect(SessionSelection.openIDs(selection(root)) == nil)
        }
    }
}
