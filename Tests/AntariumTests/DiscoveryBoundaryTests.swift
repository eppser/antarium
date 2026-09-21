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

/// Which sessions a harness reports as still open. The refusals are covered
/// above — a corrupt window, a missing id, an oversized file — and what an
/// ordinary selection returns was not. An empty answer here hides every open
/// session of that agent, which looks like nobody is working.
@Suite("Open-session selection returns what is open", .serialized)
struct OpenSelectionTests {

    private func selection(_ object: [String: Any]) throws
        -> HarnessDescriptor.Selection {
        let wrapper: [String: Any] = [
            "formatVersion": 1, "id": "selection-fixture", "name": "Fixture",
            "process": [:], "source": ["kind": "none", "path": ""],
            "selection": object]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: wrapper)).descriptor
        return try #require(descriptor.sessionSelection)
    }

    private func stateFile(_ body: [String: Any]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: body)
            .write(to: dir.appendingPathComponent("state.json"))
        return dir
    }

    @Test("Every record's id is reported")
    func allIDs() throws {
        let dir = try stateFile(["tabs": [["id": "one"], ["id": "two"]]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = SessionSelection.openIDs(try selection([
            "kind": "jsonFiles", "path": dir.path, "glob": "*.json",
            "records": "tabs", "id": "id"]))
        #expect(found == ["one", "two"])
    }

    /// A filter is how a harness says which tabs count. Ignoring it reports
    /// every session the file has ever held as currently open.
    @Test("A filter narrows the selection to the records that match")
    func filterNarrows() throws {
        let dir = try stateFile(["tabs": [
            ["id": "open-one", "state": "open"],
            ["id": "closed-one", "state": "closed"],
            ["id": "open-two", "state": "open"]]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = SessionSelection.openIDs(try selection([
            "kind": "jsonFiles", "path": dir.path, "glob": "*.json",
            "records": "tabs", "id": "id", "filter": ["state": ["open"]]]))
        #expect(found == ["open-one", "open-two"])
    }

    /// Booleans and numbers are compared as text, because a descriptor
    /// declares its filter values as strings.
    @Test("A filter matches a boolean or a number written as text")
    func filterCoercesScalars() throws {
        let dir = try stateFile(["tabs": [
            ["id": "live", "active": true, "pane": 2],
            ["id": "dead", "active": false, "pane": 3]]])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SessionSelection.openIDs(try selection([
            "kind": "jsonFiles", "path": dir.path, "glob": "*.json",
            "records": "tabs", "id": "id", "filter": ["active": ["true"]]])) == ["live"])
        #expect(SessionSelection.openIDs(try selection([
            "kind": "jsonFiles", "path": dir.path, "glob": "*.json",
            "records": "tabs", "id": "id", "filter": ["pane": ["3"]]])) == ["dead"])
    }

    /// No matching records is an answer — that agent has nothing open — and
    /// is not the same as being unable to tell, which withholds the filter
    /// entirely rather than hiding every session.
    @Test("No matching records is an empty selection, not a failure")
    func emptyIsAnAnswer() throws {
        let dir = try stateFile(["tabs": [["id": "one", "state": "closed"]]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = SessionSelection.openIDs(try selection([
            "kind": "jsonFiles", "path": dir.path, "glob": "*.json",
            "records": "tabs", "id": "id", "filter": ["state": ["open"]]]))
        #expect(found == [])
    }

    @Test("A descriptor with no selection declares nothing to filter by")
    func noSelection() {
        #expect(SessionSelection.openIDs(nil) == nil)
    }
}
