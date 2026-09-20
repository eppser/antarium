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
