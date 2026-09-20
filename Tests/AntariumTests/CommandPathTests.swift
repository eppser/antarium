import Foundation
import Testing
@testable import Antarium

/// Finding a command is what decides whether an agent counts as installed. It
/// had three implementations — onboarding, click-routing, and the quota
/// providers — and they had drifted apart.
@Suite("One place decides where a command lives")
struct CommandPathTests {

    private func bin(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let file = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: file.path)
        }
        return dir
    }

    @Test("A bare name is found where it is installed")
    func bareName() throws {
        let dir = try bin(["synthetic-agent"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = CommandPath.resolve("synthetic-agent", in: [dir.path])
        #expect(found == dir.appendingPathComponent("synthetic-agent").path)
    }

    @Test("A name that is not installed resolves to nothing")
    func missingName() throws {
        let dir = try bin([])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(CommandPath.resolve("synthetic-agent", in: [dir.path]) == nil)
    }

    @Test("The first place holding it wins")
    func orderIsRespected() throws {
        let first = try bin(["dup"]), second = try bin(["dup"])
        defer { try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second) }
        #expect(CommandPath.resolve("dup", in: [first.path, second.path])
                == first.appendingPathComponent("dup").path)
    }

    @Test("A file that is present but not executable is not a command")
    func nonExecutableIsNotFound() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("inert")
        try Data("text".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: file.path)
        #expect(CommandPath.resolve("inert", in: [dir.path]) == nil)
    }

    @Test("A command given as a path is taken as one, and checked")
    func explicitPath() throws {
        let dir = try bin(["direct"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("direct").path
        #expect(CommandPath.resolve(path, in: []) == path)
        #expect(CommandPath.resolve(dir.appendingPathComponent("absent").path, in: []) == nil)
    }

    @Test("Nothing resolves to nothing", arguments: ["", "with\0null"])
    func refusals(_ command: String) {
        #expect(CommandPath.resolve(command) == nil)
    }

    /// The bug this consolidation fixes. Claude's own native installer puts
    /// its binary in ~/.local/bin, as do `uv tool install` and `pipx`. The
    /// quota providers' copy of this list left it out, so a credential
    /// command installed there was runnable by a click and reported "not
    /// signed in" by the bar — the agent was installed and the thing whose
    /// job is to notice said no.
    @Test("The places searched include where agents are actually installed")
    func placesCoverRealInstallations() {
        // Inheriting nothing, so this is only what CommandPath itself adds.
        let places = CommandPath.places(inheriting: "")
        #expect(places.contains { $0.hasSuffix("/.local/bin") },
                "the native installer's directory")
        for expected in CommandPath.fallbacks {
            #expect(places.contains(expected), "\(expected) is missing")
        }
        // And the inherited PATH still comes first, so a user who has put a
        // different copy ahead of these keeps it.
        let inherited = CommandPath.places(inheriting: "/first:/second")
        #expect(Array(inherited.prefix(2)) == ["/first", "/second"])
    }

    /// The three call sites must agree, which is the whole point of there
    /// being one of them. Stated over the shipped descriptors: whatever a
    /// descriptor names as a credential command, onboarding and the provider
    /// have to reach the same verdict about it.
    @Test("Onboarding and the quota providers agree about what is installed")
    func callSitesAgree() throws {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        var checked = 0
        for url in urls {
            let descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            guard let credential = descriptor.quota?.credential,
                  credential.kind == "command",
                  let command = credential.command else { continue }
            let provider = try #require(DescriptorProvider(descriptor))
            ConfiguredProbe.invalidate()
            #expect(provider.isConfigured == (CommandPath.resolve(command) != nil),
                    Comment(rawValue: "\(descriptor.id): \(command)"))
            checked += 1
        }
        #expect(checked >= 1, "no command credentials ship, so this proved nothing")
    }
}
