import Foundation
import SQLite3
import Testing
import AntariumHarnessSDK
@testable import Antarium

@Suite("Architecture contracts", .serialized)
struct ArchitectureContractTests {
    private func row(id: String, agentID: String = "test", cwd: String = "/project",
                     pid: Int32? = nil, host: String? = nil,
                     state: AgentRow.State = .waiting) -> AgentRow {
        var value = AgentRow(id: id, agentID: agentID, name: "Project",
                             cwd: cwd, state: state, pid: pid)
        value.hostApp = host
        return value
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antarium-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func descriptor(id: String, source: [String: Any], map: [String: Any] = [:],
                            detached: Bool? = nil,
                            capabilities: [String: Any]? = nil,
                            selection: [String: Any]? = nil,
                            quota: [String: Any]? = nil) throws -> HarnessDescriptor {
        var object: [String: Any] = [
            "id": id,
            "name": id,
            "match": [] as [String],
            "source": source,
            "map": map,
        ]
        if let detached { object["detached"] = detached }
        if let capabilities { object["capabilities"] = capabilities }
        if let selection { object["selection"] = selection }
        if let quota { object["quota"] = quota }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(HarnessDescriptor.self, from: data)
    }

    @Test("Changing a descriptor reparses unchanged source bytes")
    func descriptorFingerprintInvalidatesParsedSessions() throws {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try Data("{\"oldModel\":\"old\",\"newModel\":\"new\"}\n".utf8).write(to: file)
        let id = "reload-\(UUID().uuidString)"
        let source: [String: Any] = ["kind": "jsonl", "path": root.path,
                                     "glob": "session.jsonl"]
        let old = try descriptor(id: id, source: source, map: ["model": "oldModel"])
        let new = try descriptor(id: id, source: source, map: ["model": "newModel"])

        HarnessEngine.invalidate()
        #expect(HarnessEngine.sessions(old).first?.model == "old")
        HarnessEngine.invalidate()
        #expect(HarnessEngine.sessions(new).first?.model == "new",
                "A mapping edit must not reuse a session parsed by the previous mapping")
    }

    @Test("A manifest is part of the source fingerprint")
    func manifestChangesInvalidateSessions() throws {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"model\":\"m\"}\n".utf8).write(to: root.appendingPathComponent("wire.jsonl"))
        let manifest = root.appendingPathComponent("state.json")
        try Data(#"{"cwd":"/first"}"#.utf8).write(to: manifest)
        let id = "manifest-\(UUID().uuidString)"
        let source: [String: Any] = [
            "kind": "jsonl", "path": root.path, "glob": "wire.jsonl",
            "manifest": ["file": "state.json", "map": ["cwd": "cwd"]],
        ]
        let value = try descriptor(id: id, source: source, map: ["model": "model"])

        HarnessEngine.invalidate()
        #expect(HarnessEngine.sessions(value).first?.cwd == "/first")
        try Data(#"{"cwd":"/second-project"}"#.utf8).write(to: manifest, options: .atomic)
        #expect(HarnessEngine.sessions(value).first?.cwd == "/second-project",
                "Auxiliary files must participate in cache invalidation")
    }

    @Test("Deleting a source file removes its session even when the newest mtime is unchanged")
    func sourceSetChangesInvalidateSessions() throws {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.json")
        let newest = root.appendingPathComponent("new.json")
        try Data(#"{"title":"old"}"#.utf8).write(to: old)
        try Data(#"{"title":"new"}"#.utf8).write(to: newest)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(100)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newest.path)
        let value = try descriptor(
            id: "set-\(UUID().uuidString)",
            source: ["kind": "json", "path": root.path, "glob": "*.json"],
            map: ["title": "title"])

        HarnessEngine.invalidate()
        #expect(HarnessEngine.sessions(value).count == 2)
        try FileManager.default.removeItem(at: old)
        #expect(HarnessEngine.sessions(value).count == 1,
                "A source fingerprint must include names, not only the maximum mtime")
    }

    @Test("SQLite WAL writes invalidate cached sessions")
    func sqliteWALChangesInvalidateSessions() throws {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("sessions.sqlite").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        guard let database else { return }
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database,
            "CREATE TABLE sessions (id TEXT, title TEXT, updated INTEGER)",
            nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database,
            "INSERT INTO sessions VALUES ('one','first',1700000000)",
            nil, nil, nil) == SQLITE_OK)

        let value = try descriptor(
            id: "wal-\(UUID().uuidString)",
            source: [
                "kind": "sqlite", "path": path,
                "query": "SELECT id, title, updated FROM sessions ORDER BY updated DESC",
                "columns": ["sessionID", "title", "lastActivity"],
            ])
        HarnessEngine.invalidate()
        #expect(HarnessEngine.sessions(value).first?.title == "first")

        #expect(sqlite3_exec(database,
            "INSERT INTO sessions VALUES ('two','second',1800000000)",
            nil, nil, nil) == SQLITE_OK)
        #expect(HarnessEngine.sessions(value).first?.title == "second",
                "Writes present only in the WAL are live data and cannot be hidden by a main-file cache")
    }

    @Test("A nonzero subprocess exit is not a successful value")
    func subprocessExitStatusIsPreserved() {
        #expect(Shell.run("/bin/sh", ["-c", "printf misleading; exit 7"]) == nil,
                "Stdout from a failed command must not be accepted as valid harness data")
    }

    @Test("A timeout is a hard upper bound")
    func subprocessTimeoutIsBounded() {
        let began = ProcessInfo.processInfo.systemUptime
        _ = Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 2"], timeout: 0.1)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        #expect(elapsed < 1,
                "Timeouts must escalate beyond SIGTERM so one harness cannot stall every scan")
    }

    @Test("Subprocess capture retains only the configured suffix")
    func subprocessOutputIsBoundedWhileDraining() {
        let result = Shell.execute(
            "/bin/sh",
            ["-c", "i=0; while [ $i -lt 4096 ]; do printf x; i=$((i+1)); done"],
            outputLimit: 128)

        #expect(result.succeeded)
        #expect(result.stdout.utf8.count == 128)
        #expect(result.stdout == String(repeating: "x", count: 128))
    }

    @Test("Agent-specific capabilities never claim another agent's configuration")
    func projectCapabilitiesAreAgentSpecific() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let skills = root.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: skills.appendingPathComponent("skill.md"))

        let emptySource: [String: Any] = ["kind": "none", "path": ""]
        let claudeDescriptor = try descriptor(
            id: "claude-code",
            source: emptySource,
            capabilities: [
                "skills": [
                    "probe": "directory",
                    "project": [".claude/skills"],
                    "inherited": ["~/.claude/skills"],
                ],
            ])
        let codexDescriptor = try descriptor(id: "codex", source: emptySource)

        ProjectContext.invalidate()
        let claude = ProjectContext.scan(root.path, agentID: "claude-code",
                                         descriptor: claudeDescriptor)
        let codex = ProjectContext.scan(root.path, agentID: "codex",
                                        descriptor: codexDescriptor)
        #expect(claude.capabilities.first { $0.kind == .skills }?.isPresent == true)
        #expect(codex.capabilities.first { $0.kind == .skills }?.isPresent == false,
                "Claude skills are not evidence that a Codex session has skills")
    }

    @Test("Logical session identity survives process replacement")
    func sessionIdentityDoesNotDependOnPIDWhenStableEvidenceExists() {
        let first = AgentIdentity.local(harness: "agent", sessionID: "session-1",
                                        cwd: "/work/project", pid: 100)
        let replacement = AgentIdentity.local(harness: "agent", sessionID: "session-1",
                                              cwd: "/work/project", pid: 900)
        #expect(first == replacement)

        let processOnly = AgentIdentity.local(harness: "agent", sessionID: nil,
                                              cwd: "", pid: 100)
        let otherProcess = AgentIdentity.local(harness: "agent", sessionID: nil,
                                               cwd: "", pid: 900)
        #expect(processOnly != otherProcess,
                "PID is valid only as a last-resort identity when no stable session evidence exists")
    }

    @Test("tmux state is sampled once per scan")
    func tmuxLookupIsOneSnapshot() {
        var rows = [
            row(id: "one", pid: 21, host: "tmux"),
            row(id: "two", pid: 31, host: "tmux"),
        ]
        let parents: [Int32: Int32] = [21: 20, 31: 30]
        var samples = 0

        AgentScan.attachTmuxTargets(to: &rows, parents: parents) {
            samples += 1
            return [20: "s:@1.%1", 30: "s:@2.%2"]
        }

        #expect(samples == 1)
        #expect(rows.map(\.tmuxTarget) == ["s:@1.%1", "s:@2.%2"])
    }

    @Test("A scan batch contains one row per observation")
    func localAndCloudRowsMergeWithoutDuplicates() {
        let local = [row(id: "local"), row(id: "shared")]
        let cloud = [row(id: "cloud", state: .cloud("running")),
                     row(id: "shared", state: .cloud("running"))]
        let merged = AgentScan.merge(local: local, cloud: cloud)

        #expect(Set(merged.map(\.id)) == ["local", "shared", "cloud"])
        #expect(merged.count == 3)
    }

    @Test("Only the newest scan generation may publish")
    func staleScanCannotOverwriteNewerRows() {
        var generations = ScanGeneration()
        let first = generations.begin()
        let replacement = generations.begin()

        #expect(generations.isCurrent(first) == false)
        #expect(generations.isCurrent(replacement) == true)
    }

    @Test("Malformed cloud payloads are failures, not empty success")
    func cloudParsingPreservesFailureAndIdentity() throws {
        #expect(throws: CloudScan.ParseError.self) {
            _ = try CloudScan.rows(from: ["unexpected": []])
        }

        let rows = try CloudScan.rows(from: [
            "items": [[
                "id": "task-1",
                "title": "Investigate",
                "status": "running",
                "updated_at": "2026-08-25T12:00:00Z",
            ]],
        ])
        #expect(rows.count == 1)
        #expect(rows.first?.id == "codex-cloud-task-1")
        #expect(rows.first?.isRemote == true)
    }

    @Test("Open-session selection is descriptor data")
    func tabSelectionHasNoHarnessSpecificCodePath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = [
            "tabs": #"""
            [
                {"type":"session","sessionId":"one"},
                {"type":"settings"}
            ]
            """#,
        ]
        let data = try JSONSerialization.data(withJSONObject: state)
        try data.write(to: root.appendingPathComponent("window-a.dat"))

        let value = try descriptor(
            id: "not-opencode",
            source: ["kind": "none", "path": ""],
            selection: [
                "kind": "jsonFiles",
                "path": root.path,
                "glob": "window-*.dat",
                "records": "tabs",
                "encodedJSON": true,
                "id": "sessionId",
                "filter": ["type": ["session"]],
            ])

        #expect(SessionSelection.openIDs(value.sessionSelection) == ["one"])
    }

    @Test("TOML capabilities require the declared table or key")
    func unrelatedConfigDoesNotLightCapability() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirectory = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: configDirectory,
                                                withIntermediateDirectories: true)
        let config = configDirectory.appendingPathComponent("config.toml")
        try Data("model = \"gpt\"\n".utf8).write(to: config)
        let value = try descriptor(
            id: "toml-agent",
            source: ["kind": "none", "path": ""],
            capabilities: [
                "mcp": [
                    "probe": "toml",
                    "project": [".codex/config.toml"],
                    "keys": ["mcp_servers"],
                ],
            ])

        ProjectContext.invalidate()
        let absent = ProjectContext.scan(root.path, agentID: value.id, descriptor: value)
        #expect(absent.capabilities.first { $0.kind == .mcp }?.isPresent == false)

        try Data("[mcp_servers.docs]\nurl = \"https://example.test\"\n".utf8).write(to: config)
        ProjectContext.invalidate()
        let present = ProjectContext.scan(root.path, agentID: value.id, descriptor: value)
        #expect(present.capabilities.first { $0.kind == .mcp }?.isPresent == true)
    }

    @Test("Descriptor-backed providers refresh when their configuration changes")
    func editedQuotaDescriptorReplacesProvider() throws {
        func quota(_ endpoint: String) -> [String: Any] {
            [
                "endpoint": endpoint,
                "windows": ["usedPercent": "used"],
            ]
        }
        let source: [String: Any] = ["kind": "none", "path": ""]
        let old = try descriptor(id: "quota-edit", source: source,
                                 quota: quota("https://old.example.test"))
        let new = try descriptor(id: "quota-edit", source: source,
                                 quota: quota("https://new.example.test"))

        let first = ProviderRegistry.providers(from: [old])
        let replacement = ProviderRegistry.providers(from: [new])
        #expect(first.first !== replacement.first,
                "The cached provider must not retain an earlier endpoint or mapping")
    }

    @Test("Cost is derived from token facts under the current price table")
    func cachedTokensCanBeRepricedWithoutReparsing() {
        var stats = TranscriptStats()
        stats.recordUsage(model: "model", input: 1_000_000, output: 500_000,
                          cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)

        let first = stats.estimatedCost { _ in
            Pricing.Rate(input: 1, output: 2, cacheWrite5m: 1.25,
                         cacheWrite1h: 2,
                         cacheRead: 0.1, contextWindow: 100)
        }
        let changed = stats.estimatedCost { _ in
            Pricing.Rate(input: 2, output: 4, cacheWrite5m: 2.5,
                         cacheWrite1h: 4,
                         cacheRead: 0.2, contextWindow: 100)
        }
        #expect(first == 2)
        #expect(changed == 4)
    }

    @Test("Pricing configuration owns every billed token category")
    func pricingDoesNotInferCacheRatesInCode() throws {
        let url = try #require(AppResources.bundle.url(
            forResource: "pricing", withExtension: "json"))
        let root = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["asOf"] as? String == "2026-08-25")
        let models = try #require(root["models"] as? [[String: Any]])
        let sonnet = try #require(models.first {
            $0["prefix"] as? String == "claude-sonnet-5"
        })

        #expect(sonnet["cacheWrite5m"] as? Double == 2.5)
        #expect(sonnet["cacheWrite1h"] as? Double == 4)
        #expect(sonnet["cacheRead"] as? Double == 0.2)
    }

    @Test("Five-minute and one-hour cache writes retain distinct prices")
    func cacheCreationTTLIsNotFlattened() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("session.jsonl")
        let line = #"{"timestamp":"2026-08-25T12:00:00Z","message":{"model":"model","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":3000000,"cache_creation":{"ephemeral_5m_input_tokens":1000000,"ephemeral_1h_input_tokens":2000000},"cache_read_input_tokens":0}}}"#
        try Data((line + "\n").utf8).write(to: transcript)
        let stats = try #require(TranscriptStats.of(transcript))

        let cost = stats.estimatedCost { _ in
            Pricing.Rate(input: 1, output: 1, cacheWrite5m: 2,
                         cacheWrite1h: 4, cacheRead: 0.1,
                         contextWindow: 100)
        }
        #expect(cost == 10)
    }

    @Test("Run metadata never persists raw command arguments")
    func runRecordsDoNotStorePromptsOrSecrets() throws {
        let value = RunWrapper.metadata(
            command: "agent",
            arguments: ["--token", "secret-value"],
            cwd: "/work",
            tty: nil,
            startedAt: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)

        #expect(json.contains(#""argumentCount":2"#))
        #expect(!json.contains("--token"))
        #expect(!json.contains("secret-value"))
    }

    @Test("The public SDK emits a configuration the runtime accepts")
    func sdkAndRuntimeShareACompatibilityContract() throws {
        var config = HarnessConfig(
            id: "sdk-agent",
            name: "SDK Agent",
            match: ["/sdk-agent"],
            source: .init(kind: .jsonl, path: "~/.sdk-agent/sessions",
                          glob: "*.jsonl"),
            map: .init(cwd: "cwd", model: "model", sessionID: "id"))
        config.capabilities = [
            "skills": .init(probe: .directory,
                            project: [".agent/skills"]),
        ]
        config.selection = .init(
            path: "~/.sdk-agent/state",
            glob: "window-*.json",
            records: "tabs",
            id: "sessionId",
            filter: ["type": ["session"]])

        let data = try config.encoded()
        let authored = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(authored["$schema"] as? String == "../harness.schema.json")
        let runtime = try HarnessDocument.decode(data).descriptor
        #expect(runtime.id == "sdk-agent")
        #expect(runtime.fields.sessionID == "id")
        #expect(runtime.capabilityRules["skills"]?.resolvedProbe == .directory)
        #expect(runtime.sessionSelection?.records == "tabs")
    }

    @Test("Multi-session SQLite identity may come from a declared column")
    func sdkAcceptsSQLiteSessionIdentity() throws {
        var source = HarnessConfig.Source(kind: .sqlite, path: "/tmp/sessions.sqlite")
        source.query = "SELECT id FROM sessions"
        source.columns = ["sessionID"]
        var config = HarnessConfig(
            id: "sqlite-tabs", name: "SQLite tabs", match: [], source: source)
        config.multiSession = true

        try config.validate()
    }

    @Test("SwiftPM builds contain the canonical harness and pricing resources")
    func packageResourcesAreAvailableOutsideAnAppBundle() {
        #expect(AppResources.bundle.url(
            forResource: "pricing", withExtension: "json") != nil)
        #expect(AppResources.bundle.url(
            forResource: "harness.schema", withExtension: "json") != nil)
        #expect((AppResources.bundle.urls(
            forResourcesWithExtension: "json",
            subdirectory: "harnesses") ?? []).count >= 10)
    }

    @Test("Codex goal state follows SQLite WAL updates")
    func codexGoalsDoNotFreezeAtTheMainDatabaseMtime() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("goals.sqlite").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        guard let database else { return }
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK)
        let ddl = """
        CREATE TABLE thread_goals (
          thread_id TEXT PRIMARY KEY NOT NULL,
          objective TEXT NOT NULL,
          status TEXT NOT NULL,
          tokens_used INTEGER NOT NULL,
          token_budget INTEGER
        );
        INSERT INTO thread_goals VALUES ('thread','Ship it','active',100,1000);
        """
        #expect(sqlite3_exec(database, ddl, nil, nil, nil) == SQLITE_OK)
        #expect(CodexGoals.all(at: path)["thread"]?.isRunning == true)

        #expect(sqlite3_exec(database,
            "UPDATE thread_goals SET status='complete' WHERE thread_id='thread'",
            nil, nil, nil) == SQLITE_OK)
        #expect(CodexGoals.all(at: path)["thread"]?.isRunning == false)
    }

    @Test("Capability cache follows configured filesystem evidence")
    func capabilityChangesAppearWithoutManualInvalidation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try descriptor(
            id: "live-capability",
            source: ["kind": "none", "path": ""],
            capabilities: [
                "skills": [
                    "probe": "directory",
                    "project": [".agent/skills"],
                ],
            ])

        ProjectContext.invalidate()
        let absent = ProjectContext.scan(root.path, agentID: value.id, descriptor: value)
        #expect(absent.capabilities.first { $0.kind == .skills }?.isPresent == false)

        let directory = root.appendingPathComponent(".agent/skills")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: directory.appendingPathComponent("SKILL.md"))
        let present = ProjectContext.scan(root.path, agentID: value.id, descriptor: value)
        #expect(present.capabilities.first { $0.kind == .skills }?.isPresent == true)
    }

    @Test("Harness failures stay distinguishable from zero sessions")
    func sourceHealthPreservesCommandAndQueryErrors() throws {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let command = try descriptor(
            id: "failed-command-\(UUID().uuidString)",
            source: [
                "kind": "command",
                "path": "",
                "command": "/bin/sh",
                "args": ["-c", "printf diagnostic >&2; exit 9"],
                "refreshEvery": 0,
            ])
        #expect(HarnessEngine.sessions(command).isEmpty)
        #expect(HarnessEngine.health(for: command.id)?.message.contains("exit 9") == true)

        let empty = try descriptor(
            id: "empty-command-\(UUID().uuidString)",
            source: [
                "kind": "command",
                "path": "",
                "command": "/bin/sh",
                "args": ["-c", "exit 0"],
                "refreshEvery": 0,
            ])
        #expect(HarnessEngine.sessions(empty).isEmpty)
        #expect(HarnessEngine.health(for: empty.id)?.message.contains("no JSON") == true,
                "An empty successful process is not a healthy empty data source")

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("bad.sqlite").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        if let database { sqlite3_close(database) }
        let sqlite = try descriptor(
            id: "failed-query-\(UUID().uuidString)",
            source: [
                "kind": "sqlite",
                "path": path,
                "query": "SELECT missing FROM nowhere",
                "columns": ["title"],
            ])
        #expect(HarnessEngine.sessions(sqlite).isEmpty)
        #expect(HarnessEngine.health(for: sqlite.id)?.message.contains("query") == true)
    }

    @Test("SQLite harness inspection samples the declared columns")
    func sqliteInspectionUsesRealRows() throws {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("inspect.sqlite").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        guard let database else { return }
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database,
            "CREATE TABLE sessions (id TEXT, tokens INTEGER); INSERT INTO sessions VALUES ('live', 42)",
            nil, nil, nil) == SQLITE_OK)

        let value = try descriptor(
            id: "inspect-\(UUID().uuidString)",
            source: [
                "kind": "sqlite",
                "path": path,
                "query": "SELECT id, tokens FROM sessions",
                "columns": ["sessionID", "inputTokens"],
            ])
        let sample = HarnessEngine.sampleRecords(value)

        #expect(sample.records.count == 1)
        #expect(sample.records.first?["sessionID"] as? String == "live")
        #expect(sample.records.first?["inputTokens"] as? Int == 42)
    }

    @Test("Folder-derived session fields are descriptor data")
    func pathFieldsDeriveSessionMetadata() throws {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root
            .appendingPathComponent("Project")
            .appendingPathComponent("agent-transcripts")
            .appendingPathComponent("session-42")
        try FileManager.default.createDirectory(at: session,
                                                withIntermediateDirectories: true)
        try Data("{\"role\":\"user\"}\n{\"role\":\"assistant\"}\n".utf8)
            .write(to: session.appendingPathComponent("session-42.jsonl"))

        let value = try descriptor(
            id: "path-fields-\(UUID().uuidString)",
            source: [
                "kind": "jsonl",
                "path": root.path,
                "glob": "*/agent-transcripts/*/*.jsonl",
                "pathFields": [
                    "cwd": ["ancestor": 3, "value": "name"],
                    "sessionID": ["ancestor": 1, "value": "name"],
                ],
            ],
            map: ["turnWhere": [:] as [String: String]])

        HarnessEngine.invalidate()
        let found = HarnessEngine.sessions(value).first
        #expect(found?.cwd == "Project")
        #expect(found?.sessionID == "session-42")
        #expect(found?.turns == 2)
    }

    @Test("A descriptor can bound how many newest source files are parsed")
    func sourceFileLimitIsConfiguration() throws {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.json")
        let newest = root.appendingPathComponent("new.json")
        try Data(#"{"title":"old"}"#.utf8).write(to: old)
        try Data(#"{"title":"new"}"#.utf8).write(to: newest)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: old.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: newest.path)
        let value = try descriptor(
            id: "limit-\(UUID().uuidString)",
            source: ["kind": "json", "path": root.path,
                     "glob": "*.json", "limit": 1],
            map: ["title": "title"])

        HarnessEngine.invalidate()
        let sessions = HarnessEngine.sessions(value)
        #expect(sessions.count == 1)
        #expect(sessions.first?.title == "new")
    }

    @Test("The shipped Cursor harness uses the generic file engine")
    func cursorHasNoNativeSessionReaderContract() throws {
        let urls = AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses") ?? []
        let cursorURL = try #require(urls.first { $0.lastPathComponent == "cursor.json" })
        let cursor = try HarnessDocument.decode(Data(contentsOf: cursorURL)).descriptor

        #expect(cursor.source.kind == .jsonl)
        #expect(cursor.source.pathFields?["title"]?.ancestor == 3)
        #expect(cursor.fields.turnWhere?.isEmpty == true)
    }

    @Test("Cursor usage maps plan percent windows onto gauges")
    func cursorProviderParsesCurrentPeriodUsage() throws {
        let usage: [String: Any] = [
            "billingCycleEnd": "1788250081000",
            "planUsage": [
                "totalPercentUsed": 42.5,
                "autoPercentUsed": 37.0,
                "apiPercentUsed": 96.5,
            ],
        ]
        let snapshot = try CursorProvider.makeSnapshot(usage, planName: "Pro")
        #expect(snapshot.accountLabel == "Pro")
        #expect(snapshot.gauges.count == 2)
        #expect(snapshot.gauges[0].id == "total")
        #expect(snapshot.gauges[0].used == 0.425)
        #expect(snapshot.gauges[1].id == "api")
        #expect(snapshot.gauges[1].used == 0.965)
        #expect(snapshot.extras.count == 1)
        #expect(snapshot.extras[0].id == "auto")
    }

    @Test("Cursor legacy usage buckets skip plans with no limit")
    func cursorProviderParsesLegacyUsageWhenLimitsExist() throws {
        let legacy: [String: Any] = [
            "startOfMonth": "2026-08-01T08:08:01.000Z",
            "gpt-4": ["numRequests": 150, "maxRequestUsage": 500],
        ]
        let snapshot = try CursorProvider.makeSnapshotFromLegacy(legacy, planName: nil)
        #expect(snapshot.gauges.count == 1)
        #expect(snapshot.gauges[0].id == "gpt-4")
        #expect(snapshot.gauges[0].used == 0.3)
        #expect(snapshot.gauges[0].resetsAt == nil,
                "A window start is not evidence of the next reset time")
    }

    @Test("Cursor responses without planUsage use the legacy compatibility path")
    func cursorProviderClassifiesMissingPlanUsageAsUnsupported() {
        do {
            _ = try CursorProvider.makeSnapshot(["currentPeriod": [:]], planName: nil)
            Issue.record("A response without planUsage must not be accepted")
        } catch let error as ProviderError {
            #expect(error == .unsupported("Cursor reported no plan usage."))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Cursor credentials are read from a synthetic SQLite store in read-only mode")
    func cursorProviderReadsStateDatabaseToken() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.vscdb")
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        guard let database else { return }
        #expect(sqlite3_exec(database,
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
            nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database,
            "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','fixture-token')",
            nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(CursorProvider.readTokenFromStateDB(url) == "fixture-token")
    }

    @MainActor @Test("Removing a provider clears its published quota and error")
    func quotaStoreRemovalClearsPublishedState() {
        let store = QuotaStore()
        let snapshot = Snapshot(
            providerID: "fixture",
            gauges: [Gauge(id: "period", badge: "P", title: "Period", used: 0.5,
                           resetsAt: nil, reportedSeverity: .normal)],
            extras: [], accountLabel: nil, fetchedAt: Date())
        store.set(providerID: "fixture", snapshot: snapshot)
        store.set(providerID: "fixture", error: .transport("fixture failure"), last: snapshot)

        store.remove(providerID: "fixture")

        #expect(store.snapshots["fixture"] == nil)
        #expect(store.errors["fixture"] == nil)
    }

    @Test("Cursor usage without trustworthy limits stays unsupported")
    func cursorProviderRejectsMissingLimits() {
        let usage: [String: Any] = [
            "planUsage": ["limit": 0, "includedSpend": 0],
        ]
        #expect(throws: ProviderError.self) {
            try CursorProvider.makeSnapshot(usage, planName: nil)
        }
        let legacy: [String: Any] = [
            "gpt-4": ["numRequests": 0, "maxRequestUsage": nil],
        ]
        #expect(throws: ProviderError.self) {
            try CursorProvider.makeSnapshotFromLegacy(legacy, planName: nil)
        }
    }

    @Test("Harness checking catches typos below the top-level sections")
    func harnessCheckerValidatesNestedConfiguration() {
        let object: [String: Any] = [
            "id": "bad", "name": "Bad", "match": [] as [String],
            "source": [
                "kind": "jsonl", "path": "/tmp", "glob": "*.jsonl",
                "pathFields": ["cwd": ["distance": 2, "value": "name"]],
            ],
            "map": ["status": ["field": "status", "busy": ["yes"]]],
            "capabilities": ["skills": ["proeb": "directory"]],
        ]

        let problems = HarnessCheck.schemaProblems(in: object)
        #expect(problems.contains { $0.contains("source.pathFields.cwd.distance") })
        #expect(problems.contains { $0.contains("map.status.busy") })
        #expect(problems.contains { $0.contains("capabilities.skills.proeb") })
    }

    @Test("Every shipped harness satisfies the runtime schema")
    func shippedHarnessesHaveNoStructuralProblems() throws {
        let urls = AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses") ?? []
        #expect(!urls.isEmpty)
        for url in urls {
            let data = try Data(contentsOf: url)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["formatVersion"] as? Int == HarnessDocument.currentVersion)
            #expect(object["process"] as? [String: Any] != nil)
            #expect(object["match"] == nil)
            #expect(object["matchProcessName"] == nil)
            #expect(HarnessCheck.schemaProblems(in: object).isEmpty,
                    "Invalid \(url.lastPathComponent)")
            let descriptor = try HarnessDocument.decode(data).descriptor
            #expect(descriptor.fields.toolMarker == nil,
                    "Bundled harnesses must count structured tool evidence, not JSON substrings")
        }
    }
}
