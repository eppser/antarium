import Foundation
import Testing
@testable import Antarium

@Suite("Capability observation boundaries")
struct CapabilityBoundaryTests {
    private func fixture(probe:String = "jsonObject", path:String = "settings.json") throws -> HarnessDescriptor {
        let payload: [String:Any] = ["formatVersion":1,"id":"synthetic-capability","name":"Synthetic","process":[:],
            "source":["kind":"none","path":""],
            "capabilities":["mcp":["probe":probe,"project":[path],"keys":["mcp_servers"]]]]
        return try HarnessDocument.decode(JSONSerialization.data(withJSONObject:payload)).descriptor
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capability-test-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func capability(_ root:URL,_ descriptor:HarnessDescriptor) throws -> Capability {
        try #require(ProjectContext.scan(root.path,agentID:descriptor.id,descriptor:descriptor).capabilities.first { $0.kind == .mcp })
    }
    @Test("Unreadable shape and oversized JSON are unknown, not present or absent")
    func invalidJSON() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let descriptor = try fixture()
        for text in ["{", "{\"mcp_servers\":{\"synthetic\":{}},\"padding\":\"" + String(repeating:"x",count:1_048_577) + "\"}"] {
            try Data(text.utf8).write(to:root.appendingPathComponent("settings.json"),options:.atomic)
            let result = try capability(root,descriptor)
            #expect(result.scope == .unavailable)
            #expect(result.issue != nil)
            #expect(!result.isPresent)
        }
    }
    @Test("Symbolic-link capability targets are not followed")
    func symlink() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let target = root.appendingPathComponent("target.json")
        try Data(#"{"mcp_servers":{"synthetic":{}}}"#.utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("settings.json"),withDestinationURL:target)
        #expect(try capability(root,fixture()).scope == .unavailable)
    }
    @Test("Missing and explicitly empty capabilities remain distinct from a failed probe")
    func knownAbsence() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let descriptor = try fixture()
        #expect(try capability(root,descriptor).scope == .absent)
        try Data(#"{"mcp_servers":{}}"#.utf8).write(to:root.appendingPathComponent("settings.json"))
        #expect(try capability(root,descriptor).scope == .absent)
    }
    @Test("A bounded directory probe never publishes a partial capability count")
    func directoryLimit() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let entries = root.appendingPathComponent("entries")
        try FileManager.default.createDirectory(at:entries,withIntermediateDirectories:true)
        for index in 0...4_096 { try Data().write(to:entries.appendingPathComponent("entry-\(index)")) }
        #expect(try capability(root,fixture(probe:"directory",path:"entries")).scope == .unavailable)
    }
    @Test("Content replacement cannot evade a capability cache by restoring file size and mtime")
    func replacementStamp() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("stamp")
        try Data("aaaa".utf8).write(to:file)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_000)],ofItemAtPath:file.path)
        let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
        let before = FileStamp.of(file)
        try Data("bbbb".utf8).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.modificationDate:try #require(attributes[.modificationDate])],ofItemAtPath:file.path)
        #expect(FileStamp.of(file) != before)
    }
    @Test("A multiline TOML string cannot masquerade as an active server declaration")
    func ambiguousTOML() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        try Data("message = \"\"\"\n[mcp_servers.synthetic]\n\"\"\"\n".utf8).write(to:root.appendingPathComponent("settings.toml"))
        #expect(try capability(root,fixture(probe:"toml",path:"settings.toml")).isPresent == false)
    }
    @Test("Long-lived project discovery cannot grow the context cache without a bound")
    func cacheBound() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let descriptor = try fixture()
        for index in 0..<300 {
            _ = ProjectContext.scan(root.appendingPathComponent("project-\(index)").path,agentID:descriptor.id,descriptor:descriptor)
        }
        #expect(ProjectContext.cachedContextCount <= 256)
    }
}

/// An `index` that names a folder rather than a file.
///
/// `index` exists to reveal a memory index — `MEMORY.md` inside a memory
/// folder — and counts the folder's other entries beside it. Naming a folder
/// there is a misconfiguration, and what it used to do was report that folder
/// as the capability's own file. A directory's `st_size` is a block count
/// rather than a statement about content, so the shape of the answer depended
/// on which branch happened to be reached.
@Suite("An index naming a folder", .serialized)
struct CapabilityIndexShapeTests {

    private func descriptor(index: String) throws -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "index-fixture", "name": "Index",
            "process": [:], "source": ["kind": "none", "path": ""],
            "capabilities": ["memory": ["probe": "directory",
                                        "project": ["memory"], "index": index]]]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    private func scan(_ index: String, build: (URL) throws -> Void) throws -> Capability {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-\(UUID().uuidString)")
        let memory = root.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try build(memory)
        defer { try? FileManager.default.removeItem(at: root) }
        ProjectContext.invalidate()
        let found = ProjectContext.scan(root.path, agentID: "index-fixture",
                                        descriptor: try descriptor(index: index))
        return try #require(found.capabilities.first { $0.kind == .memory })
    }

    /// The ordinary case, so the rest cannot pass by refusing everything.
    @Test("An index that is a file is revealed, and the rest are counted")
    func fileIndexIsRevealed() throws {
        let found = try scan("MEMORY.md") { memory in
            try Data("curated\n".utf8).write(to: memory.appendingPathComponent("MEMORY.md"))
            try Data("a\n".utf8).write(to: memory.appendingPathComponent("2026-09-21.md"))
        }
        #expect(found.scope == .project)
        #expect(found.url?.lastPathComponent == "MEMORY.md")
        #expect(found.count == 1, "the index counted itself among the others")
    }

    /// A folder named as the index is not the file it was meant to reveal, so
    /// the capability reports the folder it was already looking at rather
    /// than pointing at something that cannot be opened as an index.
    @Test("An index that is a folder is not revealed as one")
    func folderIndexIsNotRevealed() throws {
        let found = try scan("MEMORY.md") { memory in
            try FileManager.default.createDirectory(
                at: memory.appendingPathComponent("MEMORY.md"),
                withIntermediateDirectories: true)
            try Data("a\n".utf8).write(to: memory.appendingPathComponent("2026-09-21.md"))
        }
        #expect(found.scope == .project, "the capability vanished entirely")
        #expect(found.url?.lastPathComponent == "memory",
                "a folder was reported as the memory index")
    }

    /// And an empty file named as the index is not an index either — the
    /// same rule the rest of this app applies to a placeholder.
    @Test("An empty index file is not revealed")
    func emptyIndexIsNotRevealed() throws {
        let found = try scan("MEMORY.md") { memory in
            try Data().write(to: memory.appendingPathComponent("MEMORY.md"))
            try Data("a\n".utf8).write(to: memory.appendingPathComponent("2026-09-21.md"))
        }
        #expect(found.url?.lastPathComponent == "memory")
    }
}
