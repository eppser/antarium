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

/// The escape hatch the descriptors tell users about, end to end.
///
/// MiniMax runs two regions with the same API and different hosts —
/// `api.minimax.io` internationally, `api.minimaxi.com` in China. The shipped
/// descriptor names the international one and its note tells a China-region
/// account to "override `quota.endpoint` with api.minimaxi.com in
/// ~/.antarium/harnesses/minimax.json". Cross-read 2026-09-27 against
/// ClaudeBar's `MiniMaxRegion.swift`, which offers the same two hosts as a
/// picker and builds the identical path onto each: the split is real, and only
/// the host differs.
///
/// That instruction is a promise the app has to keep, and it spans three things
/// each tested on its own — an edited file is never overwritten, the catalogue
/// reads the folder, a provider builds its request from its descriptor — with
/// nothing asserting the sentence a user actually acts on. It is the same shape
/// as a setup hint naming a key file we do not read: the user follows it, the
/// row still says "not signed in", and nothing in the app says why.
@Suite("An edited descriptor is the one the app asks")
struct EditedDescriptorTakesEffectTests {

    /// The shipped file, seeded into a synthetic folder and then edited there —
    /// the sequence a user performs, rather than a descriptor written from
    /// scratch to look like one.
    private func seededThenEdited(_ id: String,
                                  edit: (inout [String: Any]) -> Void) throws -> HarnessDescriptor {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edited-descriptor-\(UUID())")
        let user = root.appendingPathComponent("harnesses")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shipped = try #require(AppResources.bundle.url(forResource: id,
                                                          withExtension: "json",
                                                          subdirectory: "harnesses"),
                                   Comment(rawValue: "\(id) does not ship"))
        _ = HarnessDescriptor.seed(in: user, sources: [shipped])
        let file = user.appendingPathComponent("\(id).json")
        #expect(FileManager.default.fileExists(atPath: file.path),
                Comment(rawValue: "\(id) was not seeded into the folder the app reads"))

        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file))
                                    as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        // Seeding again is what a later launch does, and an edited file must
        // survive it — otherwise the override lasts until the next start.
        _ = HarnessDescriptor.seed(in: user, sources: [shipped])
        return try HarnessDocument.decode(Data(contentsOf: file)).descriptor
    }

    @Test("A region override reaches the URL the request is built from")
    func regionOverrideIsAsked() throws {
        let china = "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains"
        let descriptor = try seededThenEdited("minimax") { object in
            var quota = object["quota"] as? [String: Any] ?? [:]
            quota["endpoint"] = china
            object["quota"] = quota
        }
        let endpoint = try #require(descriptor.quota?.endpoint)
        #expect(endpoint == china, "the edit did not survive a second seeding")
        let url = try #require(DescriptorProvider.requestURL(endpoint, token: "synthetic-token"))
        #expect(url.host == "api.minimaxi.com",
                Comment(rawValue: "a China-region override was asked at \(url.host ?? "nothing")"))
        #expect(url.path == "/v1/api/openplatform/coding_plan/remains",
                "the override changed the path as well as the host")
    }

    /// And the shipped file is the other region, so the test above is an
    /// override taking effect rather than the value that was already there.
    @Test("The shipped descriptor names the international host")
    func shippedIsInternational() throws {
        let shipped = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "minimax" })
        let endpoint = try #require(shipped.quota?.endpoint)
        #expect(endpoint.contains("api.minimax.io"),
                Comment(rawValue: "the shipped MiniMax endpoint is \(endpoint)"))
        #expect(!endpoint.contains("minimaxi"),
                "the shipped descriptor already names the China host")
    }

    /// The note has to keep saying which field to edit and what to put in it,
    /// or the instruction this suite verifies is not the one a user reads.
    @Test("The note names the field and the host it tells the user to set")
    func noteNamesTheOverride() throws {
        let shipped = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "minimax" })
        let note = shipped.note ?? ""
        #expect(note.contains("quota.endpoint"),
                "the note no longer says which field a China-region account should change")
        #expect(note.contains("api.minimaxi.com"),
                "the note no longer says what to change it to")
        #expect(note.contains("~/.antarium/harnesses/minimax.json"),
                "the note no longer says which file to change it in")
    }
}
