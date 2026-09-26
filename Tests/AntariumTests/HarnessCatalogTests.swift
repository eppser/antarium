import Foundation
import Testing
@testable import Antarium

@Suite("Read-only resilient harness catalogs")
struct HarnessCatalogTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-fixture-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func descriptor(_ id:String = "fixture",name:String = "Synthetic") throws -> Data {
        try JSONSerialization.data(withJSONObject:["formatVersion":1,"id":id,"name":name,"process":[:],"source":["kind":"none","path":""]])
    }
    @Test("A catalog read cannot create or update configuration files")
    func readOnly() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("fixture.json"); try descriptor().write(to:source)
        let destination = root.appendingPathComponent("missing-harnesses")
        let catalog = HarnessCatalog(directory:destination,defaults:[source])
        #expect(catalog.snapshot().descriptors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath:destination.path))
        #expect(catalog.seed().added == ["fixture.json"])
        #expect(catalog.snapshot(force:true).descriptors.first?.id == "fixture")
    }
    @Test("An unreadable replacement preserves the last valid descriptor and reports degraded configuration")
    func lastValid() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("fixture.json"); try descriptor().write(to:file)
        let catalog = HarnessCatalog(directory:root)
        #expect(catalog.snapshot().descriptors.first?.name == "Synthetic")
        try Data("invalid synthetic JSON".utf8).write(to:file)
        let failure = catalog.snapshot(force:true)
        #expect(failure.descriptors.first?.name == "Synthetic")
        #expect(!failure.issues.isEmpty)
        try descriptor(name:"Recovered").write(to:file)
        let recovered = catalog.snapshot(force:true)
        #expect(recovered.descriptors.first?.name == "Recovered")
        #expect(recovered.issues.isEmpty)
    }
    @Test("Directory limits cannot turn a previously valid inventory into empty or partial success")
    func capacity() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        try descriptor().write(to:root.appendingPathComponent("fixture.json"))
        let catalog = HarnessCatalog(directory:root)
        #expect(catalog.snapshot().descriptors.count == 1)
        for index in 0..<256 { try descriptor("extra-\(index)").write(to:root.appendingPathComponent("extra-\(index).json")) }
        let result = catalog.snapshot(force:true)
        #expect(result.descriptors.count == 1)
        #expect(!result.issues.isEmpty)
    }
    @Test("Ambiguous duplicate IDs cannot silently select a different descriptor")
    func conflictingIdentity() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        try descriptor().write(to:root.appendingPathComponent("original.json"))
        let catalog = HarnessCatalog(directory:root)
        #expect(catalog.snapshot().descriptors.first?.name == "Synthetic")
        try descriptor(name:"Conflicting").write(to:root.appendingPathComponent("duplicate.json"))
        let result = catalog.snapshot(force:true)
        #expect(result.descriptors.count == 1)
        #expect(result.descriptors.first?.name == "Synthetic")
        #expect(!result.issues.isEmpty)
    }
    @Test("Linked replacements retain the last valid descriptor without reading the link target")
    func linkedReplacement() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("fixture.json"), target = root.appendingPathComponent("target.txt")
        try descriptor().write(to:file)
        let catalog = HarnessCatalog(directory:root)
        #expect(catalog.snapshot().descriptors.count == 1)
        try descriptor(name:"Must not load").write(to:target)
        try FileManager.default.removeItem(at:file)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
        let result = catalog.snapshot(force:true)
        #expect(result.descriptors.first?.name == "Synthetic")
        #expect(!result.issues.isEmpty)
    }
    @Test("Missing directories and oversized files preserve the catalog; explicit deletion is reflected")
    func replacementLimits() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let folder = root.appendingPathComponent("harnesses")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file = folder.appendingPathComponent("fixture.json")
        try descriptor().write(to:file)
        let catalog = HarnessCatalog(directory:folder)
        #expect(catalog.snapshot().descriptors.count == 1)
        try Data(repeating:32,count:1_048_577).write(to:file)
        #expect(catalog.snapshot(force:true).descriptors.count == 1)
        try FileManager.default.removeItem(at:folder)
        #expect(catalog.snapshot(force:true).descriptors.count == 1)
        #expect(!catalog.issues.isEmpty)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let recovered = catalog.snapshot(force:true)
        #expect(recovered.descriptors.isEmpty)
        #expect(recovered.issues.isEmpty)
    }
    @Test("A failed directory fingerprint is distinct from a successfully empty directory")
    func failedFingerprint() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        #expect(FileStamp.ofDirectory(root) != FileStamp.ofDirectory(root.appendingPathComponent("missing")))
    }

}
