import Foundation
import Testing
@testable import Antarium

/// What a row is allowed to claim about a project. The distinction these hold
/// is between missing, empty and present: an empty CLAUDE.md is not
/// instructions, an empty `.claude/skills` is not skills, and a commented-out
/// server is not MCP. Claiming otherwise tells the user their project is
/// configured when it is not.
@Suite("Capability probes distinguish empty from present", .serialized)
struct CapabilityPresenceTests {

    private func project(_ build: (URL) throws -> Void) rethrows -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capability-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func descriptor(_ rules: [String: Any]) throws -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "capability-fixture", "name": "Fixture",
            "process": [:], "source": ["kind": "none", "path": ""],
            "capabilities": rules]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    private func scope(_ root: URL, _ rules: [String: Any], _ kind: Capability.Kind)
        throws -> Capability.Scope {
        ProjectContext.invalidate()
        let found = ProjectContext.scan(root.path, agentID: "capability-fixture",
                                        descriptor: try descriptor(rules))
        return try #require(found.capabilities.first { $0.kind == kind }).scope
    }

    private let contentRule: [String: Any] =
        ["instruction": ["probe": "content", "project": ["NOTES.md"]]]
    private let directoryRule: [String: Any] =
        ["skills": ["probe": "directory", "project": ["skills"]]]

    // MARK: - content

    @Test("A file with something in it is present")
    func fileWithContent() throws {
        let root = try project { try Data("guidance".utf8).write(to: $0.appendingPathComponent("NOTES.md")) }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, contentRule, .instruction) == .project)
    }

    /// An empty file is the shape a half-finished setup leaves behind, and
    /// reporting it as configured is the wrong answer in the direction that
    /// matters — the user believes the agent is reading something.
    @Test("An empty file is not content")
    func emptyFile() throws {
        let root = try project { try Data().write(to: $0.appendingPathComponent("NOTES.md")) }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, contentRule, .instruction) == .absent)
    }

    @Test("A file that is not there is absent")
    func missingFile() throws {
        let root = try project { _ in }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, contentRule, .instruction) == .absent)
    }

    // MARK: - directory

    @Test("A directory with an entry in it is present")
    func directoryWithEntries() throws {
        let root = try project {
            let dir = $0.appendingPathComponent("skills")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("one.md"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, directoryRule, .skills) == .project)
    }

    @Test("An empty directory is not skills")
    func emptyDirectory() throws {
        let root = try project {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent("skills"),
                                                     withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, directoryRule, .skills) == .absent)
    }

    /// A content probe pointed at a directory asks a different question of it
    /// — does it hold anything — so a file and a directory must not be mixed
    /// up on the way in.
    @Test("A content probe on a directory asks whether it holds anything")
    func contentProbeOnDirectory() throws {
        let rule: [String: Any] = ["instruction": ["probe": "content", "project": ["docs"]]]
        let empty = try project {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent("docs"),
                                                     withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(try scope(empty, rule, .instruction) == .absent)

        let filled = try project {
            let dir = $0.appendingPathComponent("docs")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("a.md"))
        }
        defer { try? FileManager.default.removeItem(at: filled) }
        #expect(try scope(filled, rule, .instruction) == .project)
    }

    // MARK: - TOML declarations

    private let tomlRule: [String: Any] =
        ["mcp": ["probe": "toml", "project": ["config.toml"], "keys": ["mcp_servers"]]]

    @Test("A declared TOML table is present")
    func tomlTable() throws {
        let root = try project {
            try Data("[mcp_servers.synthetic]\ncommand = \"x\"\n".utf8)
                .write(to: $0.appendingPathComponent("config.toml"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, tomlRule, .mcp) == .project)
    }

    /// Commented out is switched off. Reading a `#` line as a declaration
    /// reports a server the agent will never contact.
    @Test("A commented-out declaration is not a declaration")
    func tomlComment() throws {
        let root = try project {
            try Data("# [mcp_servers.synthetic]\n# command = \"x\"\n".utf8)
                .write(to: $0.appendingPathComponent("config.toml"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, tomlRule, .mcp) == .absent)
    }

    /// `mcp_servers_disabled = …` is a different key. Matching on the prefix
    /// alone claims a setting the file does not contain.
    @Test("A key that merely starts with the one we want is a different key")
    func tomlKeyPrefix() throws {
        let root = try project {
            try Data("mcp_servers_disabled = true\n".utf8)
                .write(to: $0.appendingPathComponent("config.toml"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, tomlRule, .mcp) == .absent)
    }

    @Test("The key itself, assigned, is a declaration")
    func tomlKeyAssignment() throws {
        let root = try project {
            try Data("mcp_servers = { synthetic = 1 }\n".utf8)
                .write(to: $0.appendingPathComponent("config.toml"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, tomlRule, .mcp) == .project)
    }
}
