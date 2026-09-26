import Foundation
import Testing
@testable import Antarium

/// A relocated agent reads its project setup from the directory it moved to.
///
/// `source.relocate` covered the session store first, and the commit that added
/// it said plainly which paths it did not cover. This is the rest: the files an
/// agent keeps beside its sessions. Kimi, Hermes and OpenClaw each keep their
/// inherited instructions and skills under the root their variable relocates, so
/// following it for sessions alone left a relocated agent showing its rows and
/// reporting its project setup as absent — which reads as "you have not set this
/// up" for a user who has.
///
/// The environment is injected rather than set. Setting a variable in the test
/// process would leak into every other suite and make the result depend on the
/// order they run in.
@Suite("A relocated agent's capability paths move with it", .serialized)
struct RelocatedContextTests {

    /// A harness whose inherited instruction file lives under a relocatable
    /// root, plus a real file in a temporary directory standing in for it.
    private func harness(_ root: String) throws -> HarnessDescriptor {
        let data = Data("""
        {
          "formatVersion":1,"id":"reloc-context","name":"Reloc context",
          "process":{"pathContains":["/reloc-context"]},
          "source":{"kind":"jsonl","path":"~/.relocfix/sessions","glob":"*.jsonl",
                    "relocate":{"env":"RELOCFIX_HOME","replaces":"~/.relocfix"}},
          "capabilities":{
            "instruction":{"probe":"content","project":["AGENTS.md"],
                           "inherited":["~/.relocfix/AGENTS.md"]}
          }
        }
        """.utf8)
        _ = root
        return try HarnessDocument.decode(data).descriptor
    }

    private func temporaryRoot(withInstructions: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relocfix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if withInstructions {
            try Data("# moved instructions\n".utf8)
                .write(to: root.appendingPathComponent("AGENTS.md"))
        }
        return root
    }

    private func instruction(_ context: ProjectContext) -> Capability? {
        context.capabilities.first { $0.kind == .instruction }
    }

    /// The defect, stated as what the user sees.
    @Test("An inherited file under a relocated root is found")
    func inheritedFileIsFound() throws {
        let root = try temporaryRoot(withInstructions: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try temporaryRoot(withInstructions: false)
        defer { try? FileManager.default.removeItem(at: project) }

        let context = ProjectContext.scan(project.path, agentID: "reloc-context",
                                          descriptor: try harness(root.path),
                                          environment: ["RELOCFIX_HOME": root.path])
        let found = try #require(instruction(context))
        #expect(found.isPresent,
                "an inherited instruction file under the relocated root read as absent")
        #expect(found.url?.path == root.appendingPathComponent("AGENTS.md").path)
    }

    /// And with the variable unset, the same file is *not* found — which is the
    /// claim that proves the relocation is what found it above rather than
    /// something else.
    ///
    /// Asserted this way round because an absent capability records no URL, so
    /// there is no way to ask where it looked. What can be asked is whether the
    /// file it did not find is the one the variable would have pointed at.
    @Test("With the variable unset the relocated file is not found")
    func unsetDoesNotFollowTheRoot() throws {
        let root = try temporaryRoot(withInstructions: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try temporaryRoot(withInstructions: false)
        defer { try? FileManager.default.removeItem(at: project) }

        let context = ProjectContext.scan(project.path, agentID: "reloc-context",
                                          descriptor: try harness(root.path),
                                          environment: [:])
        let found = try #require(instruction(context))
        #expect(!found.isPresent,
                "a file under an unrelocated root was found without the variable set")
        // And with it set, the same call finds it — the two differ only in the
        // environment, which is the whole of the claim.
        let relocated = ProjectContext.scan(project.path, agentID: "reloc-context",
                                            descriptor: try harness(root.path),
                                            environment: ["RELOCFIX_HOME": root.path])
        #expect(instruction(relocated)?.isPresent == true)
    }

    /// An empty variable is not a relocation here either, so the rule the pure
    /// function follows is the rule this path follows.
    @Test("An empty variable does not relocate a capability path")
    func emptyVariableDoesNotRelocate() throws {
        let root = try temporaryRoot(withInstructions: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try temporaryRoot(withInstructions: false)
        defer { try? FileManager.default.removeItem(at: project) }
        let context = ProjectContext.scan(project.path, agentID: "reloc-context",
                                          descriptor: try harness(root.path),
                                          environment: ["RELOCFIX_HOME": "   "])
        #expect(instruction(context)?.isPresent != true)
    }

    /// A project path is relative to the checkout and must not be relocated:
    /// nothing about a repository moves because a data directory did.
    @Test("A project path is not relocated")
    func projectPathIsNotRelocated() throws {
        let root = try temporaryRoot(withInstructions: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try temporaryRoot(withInstructions: false)
        defer { try? FileManager.default.removeItem(at: project) }
        try Data("# project instructions\n".utf8)
            .write(to: project.appendingPathComponent("AGENTS.md"))

        let context = ProjectContext.scan(project.path, agentID: "reloc-context",
                                          descriptor: try harness(root.path),
                                          environment: ["RELOCFIX_HOME": root.path])
        let found = try #require(instruction(context))
        // The project file wins, and it is the one in the checkout.
        #expect(found.url?.path == project.appendingPathComponent("AGENTS.md").path,
                Comment(rawValue: "resolved to \(found.url?.path ?? "nothing")"))
    }
}

/// The other half: the files a source declares beside its sessions.
@Suite("A relocated source's other declared paths move with it")
struct RelocatedSourcePathTests {

    private var codex: HarnessDescriptor {
        get throws {
            try #require(HarnessCLI.bundledDescriptors().first { $0.id == "codex" })
        }
    }

    /// Codex keeps its autonomous-goal database at `~/.codex/goals_1.sqlite`,
    /// under the root `CODEX_HOME` moves. Following the variable for the sessions
    /// and not for this left a relocated Codex showing its rows and reporting its
    /// loop state as unavailable.
    @Test("Codex's goal database follows CODEX_HOME")
    func goalsFollowTheVariable() throws {
        let source = try codex.source
        #expect(source.declaredPathNames.contains("goals"),
                "codex no longer declares a goals path")
        #expect(source.declaredPath("goals", environment: ["CODEX_HOME": "/moved/codex"])
                == "/moved/codex/goals_1.sqlite")
    }

    @Test("With the variable unset the goal database is where it is written")
    func goalsUnsetUnchanged() throws {
        let source = try codex.source
        #expect(source.declaredPath("goals", environment: [:])
                == "~/.codex/goals_1.sqlite".expandingTilde)
    }

    /// Every other path a shipped source declares, held to the same rule: if the
    /// harness relocates and the path is under the relocated prefix, resolving it
    /// must move it. This is the claim that catches the next declared path
    /// somebody adds without thinking about relocation.
    @Test("Every declared path under a relocated prefix moves with it")
    func everyDeclaredPathMoves() {
        var checked = 0
        for descriptor in HarnessCLI.bundledDescriptors() {
            let source = descriptor.source
            guard let relocate = source.relocate else { continue }
            for name in source.declaredPathNames {
                // Asked with the variable unset first, so a path that was never
                // under the relocated prefix is skipped rather than demanded to
                // move: only the ones that would move are the claim.
                guard let here = source.declaredPath(name, environment: [:]),
                      here.hasPrefix(relocate.replaces.expandingTilde) else { continue }
                checked += 1
                let moved = source.declaredPath(name, environment: [relocate.env: "/moved"])
                #expect(moved?.hasPrefix("/moved") == true,
                        Comment(rawValue: "\(descriptor.id).\(name) resolved to "
                                + "\(moved ?? "nothing") with \(relocate.env) set"))
            }
        }
        #expect(checked >= 2,
                Comment(rawValue: "\(checked) declared paths sit under a relocated prefix"))
    }

    /// And claude-code's transcripts path is *not* relocated, because that
    /// harness deliberately declares no relocation — the evidence for
    /// CLAUDE_CONFIG_DIR contradicts itself and its note says so.
    @Test("A harness with no relocation leaves its declared paths alone")
    func noRelocationLeavesPathsAlone() throws {
        let claude = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "claude-code" })
        #expect(claude.source.relocate == nil,
                "claude-code now declares a relocation — check the note before trusting it")
        #expect(claude.source.declaredPath("transcripts",
                                          environment: ["CLAUDE_CONFIG_DIR": "/moved"])
                == "~/.claude/projects".expandingTilde)
    }
}
