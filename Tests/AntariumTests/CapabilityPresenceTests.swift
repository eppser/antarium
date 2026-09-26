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

/// Some conventions are a folder of files with one particular suffix, and the
/// agent ignores the rest. Cursor reads `.cursor/rules/*.mdc` and says plainly
/// that a `.md` there is ignored — so counting every entry would report
/// instructions for a folder the agent pays no attention to.
@Suite("A probe can count only the files that count", .serialized)
struct CapabilitySuffixFilterTests {

    private func project(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extfilter-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(".cursor/rules")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            try Data("rule\n".utf8).write(to: dir.appendingPathComponent(name))
        }
        return root
    }

    private func scope(_ root: URL, suffixes: [String]?,
                       probe: String = "directory") throws -> Capability.Scope {
        var rule: [String: Any] = ["probe": probe, "project": [".cursor/rules"]]
        if let suffixes { rule["fileSuffixes"] = suffixes }
        let object: [String: Any] = [
            "formatVersion": 1, "id": "extfilter-fixture", "name": "Fixture",
            "process": [:], "source": ["kind": "none", "path": ""],
            "capabilities": ["instruction": rule]]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        ProjectContext.invalidate()
        let found = ProjectContext.scan(root.path, agentID: "extfilter-fixture",
                                        descriptor: descriptor)
        return try #require(found.capabilities.first { $0.kind == .instruction }).scope
    }

    private func count(_ root: URL, suffixes: [String]?, probe: String) throws -> Int {
        var rule: [String: Any] = ["probe": probe, "project": [".cursor/rules"]]
        if let suffixes { rule["fileSuffixes"] = suffixes }
        let object: [String: Any] = [
            "formatVersion": 1, "id": "extfilter-fixture", "name": "Fixture",
            "process": [:], "source": ["kind": "none", "path": ""],
            "capabilities": ["instruction": rule]]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        ProjectContext.invalidate()
        let found = ProjectContext.scan(root.path, agentID: "extfilter-fixture",
                                        descriptor: descriptor)
        return try #require(found.capabilities.first { $0.kind == .instruction }).count
    }

    /// A folder reached by a content rule reports how many files are in it,
    /// the same as a directory rule would. Cursor's one rule names a folder
    /// and a file, and moving it to a content probe must not turn "4 rules"
    /// into "rules".
    @Test("A content probe counts a folder's entries, like a directory probe")
    func contentProbeCounts() throws {
        let root = try project(["a.mdc", "b.mdc", "c.mdc", "ignored.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try count(root, suffixes: [".mdc"], probe: "content") == 3)
        #expect(try count(root, suffixes: [".mdc"], probe: "directory") == 3,
                "the two probes disagree about the same folder")
    }

    /// A file has no entries to count, and reporting one would read as a
    /// folder holding a single rule.
    @Test("A content probe on a file reports no count")
    func contentProbeOnFileHasNoCount() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extfilter-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("rule\n".utf8).write(to: dir.appendingPathComponent("rules"))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try count(root, suffixes: nil, probe: "content") == 0)
    }

    @Test("A folder holding only ignored files reports nothing")
    func onlyIgnoredFiles() throws {
        let root = try project(["readme.md", "notes.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, suffixes: [".mdc"]) == .absent,
                "instructions were reported for files the agent ignores")
    }

    @Test("A folder holding the right files reports them")
    func countedFiles() throws {
        let root = try project(["style.mdc", "readme.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, suffixes: [".mdc"]) == .project)
    }

    /// Without the filter every entry counts, which is what the other
    /// conventions in this app want — the filter must be opt-in, not the
    /// new default.
    @Test("With no filter declared, every entry still counts")
    func noFilterCountsEverything() throws {
        let root = try project(["readme.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, suffixes: nil) == .project)
    }

    /// The filter matches the end of the name rather than the path
    /// extension, and Copilot is why. Its scoped instructions must end
    /// `.instructions.md`; the path extension of `style.instructions.md` is
    /// `md`, the same as a file Copilot ignores, so an extension filter would
    /// have to accept both or reject both.
    @Test("A compound suffix tells a counted file from an ignored one")
    func compoundSuffix() throws {
        let counted = try project(["style.instructions.md"])
        defer { try? FileManager.default.removeItem(at: counted) }
        #expect(try scope(counted, suffixes: [".instructions.md"]) == .project)

        let ignored = try project(["readme.md"])
        defer { try? FileManager.default.removeItem(at: ignored) }
        #expect(try scope(ignored, suffixes: [".instructions.md"]) == .absent,
                "a plain .md was counted as a scoped instruction file")
    }

    /// A `content` rule accepts a file or a folder, and Copilot's convention
    /// is both at once. If the filter applied only to the `directory` probe,
    /// that one rule would count files the agent ignores.
    @Test("A content probe filters a folder the same way")
    func contentProbeFiltersFolders() throws {
        let ignored = try project(["readme.md"])
        defer { try? FileManager.default.removeItem(at: ignored) }
        #expect(try scope(ignored, suffixes: [".instructions.md"], probe: "content") == .absent,
                "a content rule counted a folder's ignored files")

        let counted = try project(["style.instructions.md"])
        defer { try? FileManager.default.removeItem(at: counted) }
        #expect(try scope(counted, suffixes: [".instructions.md"], probe: "content") == .project)
    }

    @Test("An empty folder reports nothing, filtered or not")
    func emptyFolder() throws {
        let root = try project([])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try scope(root, suffixes: [".mdc"]) == .absent)
        #expect(try scope(root, suffixes: nil) == .absent)
    }
}

/// The conventions each shipped harness declares. These are claims about
/// somebody else's product, taken from that vendor's own documentation, and
/// a wrong one reports a capability the agent never reads.
@Suite("Shipped capability conventions")
struct ShippedCapabilityTests {

    private func descriptor(_ id: String) throws -> HarnessDescriptor {
        let url = try #require(AppResources.bundle.url(
            forResource: id, withExtension: "json", subdirectory: "harnesses"))
        return try HarnessDocument.decode(Data(contentsOf: url)).descriptor
    }

    /// Cursor's documentation states that a plain `.md` in `.cursor/rules` is
    /// ignored because it carries no frontmatter, so the probe counts `.mdc`
    /// and nothing else. The same page names `AGENTS.md` in the project root,
    /// which is a file rather than a folder — one rule covers both, because a
    /// content probe accepts either and applies the suffixes to the folder.
    @Test("Cursor reads .mdc rules from .cursor/rules, and AGENTS.md")
    func cursorRules() throws {
        let rule = try #require(try descriptor("cursor").capabilityRules["instruction"])
        #expect(rule.resolvedProbe == .content)
        #expect(rule.projectPaths == [".cursor/rules", "AGENTS.md"],
                "the folder Cursor documents first must be preferred")
        #expect(rule.countedSuffixes == [".mdc"], "an ignored file would count as instructions")
    }

    /// The CLI's own documentation says it supports the editor's rules system
    /// and additionally reads AGENTS.md and CLAUDE.md at the project root.
    /// The editor's page does not mention CLAUDE.md, so the editor harness
    /// does not claim it — the difference is the evidence, not a tidier list.
    @Test("Cursor CLI reads one file more than the editor does")
    func cursorCLIRules() throws {
        let rule = try #require(try descriptor("cursor-cli").capabilityRules["instruction"])
        #expect(rule.resolvedProbe == .content)
        #expect(rule.projectPaths == [".cursor/rules", "AGENTS.md", "CLAUDE.md"])
        #expect(rule.countedSuffixes == [".mdc"])
        let editor = try #require(try descriptor("cursor").capabilityRules["instruction"])
        #expect(editor.projectPaths.contains("CLAUDE.md") == false,
                "the editor claimed a file only the CLI documents")
    }

    /// pi loads `AGENTS.override.md` instead of `AGENTS.md` or `CLAUDE.md`
    /// when a directory has one, so the override comes first — the same shape
    /// Hermes has, and the same way to get it wrong.
    @Test("pi prefers the personal override to the committed file")
    func piContextFiles() throws {
        let rules = try descriptor("pi").capabilityRules
        let instruction = try #require(rules["instruction"])
        #expect(instruction.projectPaths
                == ["AGENTS.override.md", "AGENTS.md", "CLAUDE.md"])
        #expect(instruction.inheritedPaths == ["~/.pi/agent/AGENTS.md"])

        let skills = try #require(rules["skills"])
        #expect(skills.projectPaths == [".pi/skills", ".agents/skills"])
        #expect(skills.inheritedPaths == ["~/.pi/agent/skills", "~/.agents/skills"])
    }

    /// Hermes documents one project context file per session, first match
    /// wins, and names the chain explicitly. The probe returns the first path
    /// that matches, so the declared order *is* that chain — get it wrong and
    /// the capability names a file Hermes ignored in favour of another.
    @Test("Hermes declares its context chain in the documented order")
    func hermesContextChain() throws {
        let rules = try descriptor("hermes").capabilityRules
        let instruction = try #require(rules["instruction"])
        #expect(instruction.projectPaths == [
            ".hermes.md", "HERMES.md", "AGENTS.override.md", "AGENTS.md",
            "CLAUDE.md", ".cursorrules"])

        // The documentation is explicit that SOUL.md is loaded from
        // HERMES_HOME only and never from the working directory.
        #expect(instruction.inheritedPaths == ["~/.hermes/SOUL.md"])
        #expect(instruction.projectPaths.contains("SOUL.md") == false,
                "the persona would be read out of the project")

        #expect(try #require(rules["memory"]).inheritedPaths == ["~/.hermes/memories"])
        #expect(try #require(rules["skills"]).inheritedPaths == ["~/.hermes/skills"])
        #expect(try #require(rules["skills"]).projectPaths.isEmpty,
                "skills are documented under the home directory only")
    }

    /// OpenClaw's workspace is the session's working directory, so its
    /// bootstrap files are found where the probe already looks — no
    /// environment variable has to be read to locate them, which is unusual
    /// among these and worth pinning.
    @Test("OpenClaw reads its workspace bootstrap files")
    func openclawWorkspace() throws {
        let rules = try descriptor("openclaw").capabilityRules

        let instruction = try #require(rules["instruction"])
        #expect(instruction.resolvedProbe == .content)
        #expect(instruction.projectPaths == ["AGENTS.md", "SOUL.md"],
                "the persona would be reported as the operating instructions")

        // MEMORY.md is a sibling of memory/, not a file inside it, so this is
        // two paths rather than a directory probe with an index.
        let memory = try #require(rules["memory"])
        #expect(memory.projectPaths == ["MEMORY.md", "memory"])
        #expect(memory.resolvedProbe == .content)

        let skills = try #require(rules["skills"])
        #expect(skills.projectPaths == ["skills"])
        #expect(skills.inheritedPaths == ["~/.openclaw/skills"],
                "the managed skills are not the workspace's own")
    }

    /// Kimi Code documents a Kimi-specific location beside a generic one at
    /// every scope. The specific one is declared first throughout, which is
    /// the order its own documentation gives: Project before User, and the
    /// Kimi directory before the shared `.agents` one.
    @Test("Kimi prefers its own paths to the shared ones, at every scope")
    func kimiPaths() throws {
        let rules = try descriptor("kimi").capabilityRules

        let instruction = try #require(rules["instruction"])
        #expect(instruction.resolvedProbe == .content)
        #expect(instruction.projectPaths == [".kimi-code/AGENTS.md", "AGENTS.md"])
        #expect(instruction.inheritedPaths
                == ["~/.kimi-code/AGENTS.md", "~/.agents/AGENTS.md"])

        let skills = try #require(rules["skills"])
        #expect(skills.resolvedProbe == .directory)
        #expect(skills.projectPaths == [".kimi-code/skills", ".agents/skills"])
        #expect(skills.inheritedPaths == ["~/.kimi-code/skills", "~/.agents/skills"])

        let mcp = try #require(rules["mcp"])
        #expect(mcp.resolvedProbe == .jsonObject)
        #expect(mcp.projectPaths == [".kimi-code/mcp.json"])
        #expect(mcp.objectKeys == ["mcpServers"],
                "an empty servers object would report MCP as configured")
    }

    /// opencode documents CLAUDE.md as a fallback used only when AGENTS.md
    /// is absent, and the same for the two global files. Declaring them in
    /// that order is what makes the capability report the file opencode
    /// actually read rather than whichever the probe met first.
    @Test("opencode reads AGENTS.md before its Claude Code fallbacks")
    func opencodeRules() throws {
        let rules = try descriptor("opencode").capabilityRules
        let instruction = try #require(rules["instruction"])
        #expect(instruction.resolvedProbe == .content)
        #expect(instruction.projectPaths == ["AGENTS.md", "CLAUDE.md"],
                "the fallback would be preferred over the documented file")
        #expect(instruction.inheritedPaths
                == ["~/.config/opencode/AGENTS.md", "~/.claude/CLAUDE.md"])

        let skills = try #require(rules["skills"])
        #expect(skills.resolvedProbe == .directory)
        #expect(skills.projectPaths
                == [".opencode/skills", ".claude/skills", ".agents/skills"])
        #expect(skills.inheritedPaths
                == ["~/.config/opencode/skills", "~/.claude/skills", "~/.agents/skills"])
    }

    /// Gemini CLI's documentation names `~/.gemini/GEMINI.md` as the global
    /// context file and `GEMINI.md` in the workspace as the project one, and
    /// puts skills in `.agents/skills` or `.gemini/skills` with the `.agents`
    /// alias taking precedence.
    @Test("Gemini reads GEMINI.md and two skill folders")
    func geminiContext() throws {
        let rules = try descriptor("gemini").capabilityRules
        let instruction = try #require(rules["instruction"])
        #expect(instruction.resolvedProbe == .content)
        #expect(instruction.projectPaths == ["GEMINI.md"])
        #expect(instruction.inheritedPaths == ["~/.gemini/GEMINI.md"],
                "the global context file is not the project one")

        let skills = try #require(rules["skills"])
        #expect(skills.resolvedProbe == .directory)
        #expect(skills.projectPaths == [".agents/skills", ".gemini/skills"],
                "the documented precedence is .agents before .gemini")
        #expect(skills.inheritedPaths == ["~/.agents/skills", "~/.gemini/skills"])
    }

    /// A presence-only harness still puts a row on the dashboard — the
    /// process is the evidence — so its project context is shown like any
    /// other. This is the reason Gemini is worth a rule at all.
    @Test("A presence-only harness is still one that makes rows")
    func presenceHarnessMakesRows() throws {
        #expect(try descriptor("gemini").contributesPresenceOnly)
        #expect(try descriptor("gemini").contributesFocusOnly == false)
    }

    /// GitHub documents one convention for every Copilot surface: a
    /// repository-wide file, a scoped folder, and the shared agent files. The
    /// `vscode` and `copilot-cli` harnesses are two of those surfaces and
    /// declare the same rule; the `copilot` harness contributes no sessions,
    /// so it has no row for project context to appear on.
    @Test("Every Copilot surface reads the same documented instruction files",
          arguments: ["vscode", "copilot-cli"])
    func copilotInstructions(_ id: String) throws {
        let rule = try #require(try descriptor(id).capabilityRules["instruction"])
        #expect(rule.resolvedProbe == .content)
        #expect(rule.projectPaths == [".github/copilot-instructions.md",
                                      ".github/instructions",
                                      "AGENTS.md", "CLAUDE.md", "GEMINI.md"],
                "the repository-wide file must be preferred over the shared ones")
        #expect(rule.countedSuffixes == [".instructions.md"])
    }

    @Test("The quota-only Copilot harness declares no project context")
    func copilotQuotaOnly() throws {
        #expect(try descriptor("copilot").capabilityRules.isEmpty)
    }

    /// Zed names four project instruction files. Each is a single file, so an
    /// empty one is not instructions — a content probe, not a directory one.
    @Test("Zed reads its four project instruction files")
    func zedRules() throws {
        let rule = try #require(try descriptor("zed").capabilityRules["instruction"])
        #expect(rule.resolvedProbe == .content)
        #expect(Set(rule.projectPaths) == [".rules", ".cursorrules", "CLAUDE.md", "AGENTS.md"])
    }

    /// Every declared capability names a kind the app knows how to draw. A
    /// typo here is a rule that is read, accepted and never shown.
    @Test("Every shipped capability is one the app renders")
    func capabilitiesAreKnown() throws {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        let known = Set(Capability.Kind.allCases.map(\.rawValue))
        var declared = 0
        for url in urls {
            let descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            for (kind, _) in descriptor.capabilityRules {
                declared += 1
                #expect(known.contains(kind),
                        Comment(rawValue: "\(descriptor.id) declares \(kind), which is not drawn"))
            }
        }
        #expect(declared >= 10, "too few capabilities declared to have proved anything")
    }
}

/// Which harnesses a capability rule can usefully be written for.
///
/// Project context is attached to a row, so a harness that makes no rows has
/// nowhere to put one. Counting every descriptor without capabilities as a
/// gap overstated it by nine and would have sent the next reader hunting for
/// documentation on where GitHub Copilot's quota endpoint keeps its
/// instruction files, which is not a question.
@Suite("Capability rules belong to harnesses that make rows")
struct CapabilityApplicabilityTests {

    /// A harness puts rows on the dashboard if it reads a session source, if
    /// it names transcript paths for a native scanner, or if it reports
    /// presence from the process table alone. Focus-only harnesses
    /// deliberately make none: every pane they see is already somebody else's
    /// row.
    private func makesRows(_ d: HarnessDescriptor) -> Bool {
        if d.contributesFocusOnly { return false }
        if d.contributesPresenceOnly { return true }
        return d.source.kind != .none || !d.source.declaredPathNames.isEmpty
    }

    private var shipped: [HarnessDescriptor] {
        get throws {
            let urls = try #require(AppResources.bundle.urls(
                forResourcesWithExtension: "json", subdirectory: "harnesses"))
            return try urls.sorted { $0.path < $1.path }.map {
                try HarnessDocument.decode(Data(contentsOf: $0)).descriptor
            }
        }
    }

    @Test("No harness declares project context it can never show")
    func noDeadCapabilityRules() throws {
        for descriptor in try shipped where !descriptor.capabilityRules.isEmpty {
            #expect(makesRows(descriptor),
                    Comment(rawValue: "\(descriptor.id) declares capabilities and makes no rows"))
        }
    }

    /// The gap ECOSYSTEM.md records, compared against the descriptors rather
    /// than counted by hand.
    ///
    /// The marker is machine-readable because the prose around it was not:
    /// the count in it said fifteen for as long as nobody asked which
    /// harnesses could use a capability rule, and then said seven, five,
    /// four, two and one over an afternoon of closing them. A sentence that
    /// has to be edited by hand to stay true is a sentence that will be
    /// wrong.
    @Test("The gap marker in ECOSYSTEM.md names exactly the harnesses missing one")
    func documentedGapMatches() throws {
        let missing = try shipped
            .filter { makesRows($0) && $0.capabilityRules.isEmpty }
            .map(\.id).sorted()
        let doc = try String(contentsOf: URL(fileURLWithPath: "docs/ECOSYSTEM.md"),
                             encoding: .utf8)
        let marker = "<!-- capability-gap:"
        let line = try #require(doc.split(separator: "\n")
            .first { $0.hasPrefix(marker) }
            .map(String.init), "ECOSYSTEM.md carries no capability-gap marker")
        let listed = line.dropFirst(marker.count)
            .replacingOccurrences(of: "-->", with: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "none" }
            .sorted()
        #expect(listed == missing,
                Comment(rawValue: "the marker says \(listed) and the descriptors say \(missing)"))
    }

    /// The sentence beside the marker counts the same harnesses in prose, and
    /// prose does not get checked by anything.
    ///
    /// It said "Nine of the twenty-two", which was true of a smaller set of
    /// descriptors than ships today. The marker one paragraph above it is
    /// derived from the descriptors precisely because "a sentence that has to
    /// be edited by hand to stay true is a sentence that will be wrong" — and
    /// then the next sentence was edited by hand. Digits rather than words so
    /// there is something to compare.
    @Test("The harnesses that make no rows are counted correctly in prose")
    func documentedRowGapCount() throws {
        let all = try shipped
        let silent = try all.filter { !makesRows($0) }.count
        let doc = try String(contentsOf: URL(fileURLWithPath: "docs/ECOSYSTEM.md"),
                             encoding: .utf8)
        let sentence = "\(silent) of the \(all.count) never appear in it"
        #expect(doc.contains(sentence),
                Comment(rawValue: "ECOSYSTEM.md should say \"\(sentence)\""))
    }

    /// The set the marker is derived from, asserted separately so an empty
    /// gap cannot be reached by finding no harnesses at all.
    @Test("Most shipped harnesses make rows")
    func rowMakingHarnessesExist() throws {
        let makers = try shipped.filter(makesRows)
        #expect(makers.count >= 12,
                Comment(rawValue: "only \(makers.count) harnesses make rows"))
        #expect(makers.allSatisfy { !$0.capabilityRules.isEmpty },
                "a harness that makes rows says nothing about the project it is in")
    }
}
