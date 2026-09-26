import Foundation
import Testing
@testable import Antarium

@Suite("Harness update ownership and rollback boundaries")
struct HarnessSeedBoundaryTests {
    private func fixture() throws -> (URL,URL,URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-seed-fixture-\(UUID())")
        let user = root.appendingPathComponent("config/harnesses"), shipped = root.appendingPathComponent("bundle/fixture.json")
        try FileManager.default.createDirectory(at:user,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:shipped.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("{\"fixture\":1}".utf8).write(to:shipped)
        return (root,user,shipped)
    }
    @Test("Damaged ownership metadata is preserved and cannot authorize updates")
    func invalidManifest() throws {
        let (root,user,shipped) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let file = user.appendingPathComponent(".seed.json")
        try Data("invalid synthetic ownership data".utf8).write(to:file)
        _ = HarnessDescriptor.seed(in:user,sources:[shipped])
        #expect(try String(contentsOf:file,encoding:.utf8) == "invalid synthetic ownership data")
        #expect(!FileManager.default.fileExists(atPath:user.appendingPathComponent("fixture.json").path))
    }
    @Test("An old generated directory is never recursively deleted during an update")
    func preserveLegacyDirectory() throws {
        let (root,user,shipped) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let directory = user.appendingPathComponent("builtin")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let note = directory.appendingPathComponent("user-note.txt")
        try Data("keep this synthetic note".utf8).write(to:note)
        _ = HarnessDescriptor.seed(in:user,sources:[shipped])
        #expect(FileManager.default.fileExists(atPath:note.path))
    }
    @Test("A symlink cannot be replaced through ownership of its target's old bytes")
    func preserveSymlink() throws {
        let (root,user,shipped) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        _ = HarnessDescriptor.seed(in:user,sources:[shipped])
        let file = user.appendingPathComponent("fixture.json"), target = root.appendingPathComponent("user-target.json")
        try FileManager.default.moveItem(at:file,to:target)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
        try Data("{\"fixture\":2}".utf8).write(to:shipped)
        _ = HarnessDescriptor.seed(in:user,sources:[shipped])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath:file.path) == target.path)
        #expect(try String(contentsOf:target,encoding:.utf8) == "{\"fixture\":1}")
    }
    @Test("Untouched generated files update, while edited files remain user-owned")
    func ownership() throws {
        let (root,user,shipped) = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let file = user.appendingPathComponent("fixture.json")
        #expect(HarnessDescriptor.seed(in:user,sources:[shipped]).added == ["fixture.json"])
        try Data("{\"fixture\":2}".utf8).write(to:shipped)
        #expect(HarnessDescriptor.seed(in:user,sources:[shipped]).updated == ["fixture.json"])
        try Data("user edited synthetic configuration".utf8).write(to:file)
        try Data("{\"fixture\":3}".utf8).write(to:shipped)
        #expect(HarnessDescriptor.seed(in:user,sources:[shipped]).keptYours == ["fixture.json"])
        #expect(try String(contentsOf:file,encoding:.utf8) == "user edited synthetic configuration")
    }
}
