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
        #expect(try CodexGoals.all(at: path)["thread"]?.isRunning == true)

        #expect(sqlite3_exec(database,
            "UPDATE thread_goals SET status='complete' WHERE thread_id='thread'",
            nil, nil, nil) == SQLITE_OK)
        #expect(try CodexGoals.all(at: path)["thread"]?.isRunning == false)
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

    /// Note: this pins the *mapping*, not the scale. The fixture was authored
    /// to match the implementation's assumption that Cursor reports 0-100, so
    /// it would still pass if Cursor actually returned 0-1 fractions and every
    /// gauge were wrong by 100x. Only live non-zero usage settles that — the
    /// `displayMessage` field states the percent in words, which is the
    /// independent check.
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
        #expect(urls.count >= 20,
                "only \(urls.count) harnesses were read from the bundle")
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

/// Every provider on the bar reports numbers somebody will act on. A
/// descriptor provider is held to that by `--verify-harness-quota`, which
/// replays a recorded reply through the real mapping. A native one is held to
/// it by nothing structural: the four that exist have mapping tests because
/// whoever wrote them chose to, and the next one could ship with none and
/// nothing would say so.
///
/// This is also the third ask made checkable — every provider must be
/// exercisable without the agent installed, which is exactly what both halves
/// below require.
@Suite("Every provider's mapping is verifiable without installing it")
struct ProviderMappingCoverageTests {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Provider ids that read nothing mappable — no endpoint, no command
    /// output — and so have no mapping to verify. Each needs a reason.
    private static let noMapping: [String: String] = [:]

    @Test("A descriptor provider has a quota fixture; a native one has mapping tests")
    func everyProviderIsCovered() throws {
        let fixtures = (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Resources/quota-fixtures"),
            includingPropertiesForKeys: nil)) ?? []
        let fixtureIDs = Set(fixtures.map { $0.deletingPathExtension().lastPathComponent })

        let testSources = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Tests/AntariumTests"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined()

        // Only the native ones here. `ProviderRegistry.all` also carries the
        // descriptor providers, which are built from whatever harnesses this
        // Mac has seeded — thirteen here, six on a machine that has never run
        // the app — so counting them would make this a description of one
        // developer's laptop. The descriptor side is covered by the fixture
        // test below, which reads the bundle.
        let native = ProviderRegistry.all.filter { !($0 is DescriptorProvider) }
        #expect(native.count >= 6, "expected the native providers; saw \(native.count)")

        for provider in native {
            if let reason = Self.noMapping[provider.id] {
                #expect(!reason.isEmpty)
                continue
            }
            if fixtureIDs.contains(provider.id) { continue }
            // Its mapping has to be reachable from a test without the agent
            // present, which in practice means a static entry point.
            let type = String(describing: Swift.type(of: provider))
            #expect(testSources.contains("\(type).makeSnapshot"),
                    Comment(rawValue: "\(provider.id) has neither a quota fixture nor a test "
                            + "calling \(type).makeSnapshot, so nothing checks what it reports"))
        }

        // Naming the function is not the same as testing it. Codex satisfied
        // the line above because a privacy test called `makeSnapshot` in
        // passing to get a snapshot to redact; three mutations of its mapping
        // survived. A mutation in the catalogue is a stronger claim, because
        // mutate.sh has confirmed each one actually fails a test.
        let catalogue = try String(
            contentsOf: root.appendingPathComponent("mutations.txt"), encoding: .utf8)
        for provider in native where Self.noMapping[provider.id] == nil {
            let file = "\(String(describing: Swift.type(of: provider))).swift"
            #expect(catalogue.contains(file),
                    Comment(rawValue: "no mutation in mutations.txt touches \(file), so nothing "
                            + "has confirmed its tests can fail"))
        }
    }

    /// The settings toggle uses the rule rather than reimplementing it.
    ///
    /// A weaker check than the others here, and deliberately so: the decision
    /// it guards is made inside a SwiftUI body, which no test in this project
    /// can reach — mutating the view's wiring survives the whole suite. What
    /// this can do is notice a return to the shape the rule was extracted
    /// from, where the view kept its own copy of "never leave an empty menu
    /// bar" and enforced it by discarding the user's click in silence.
    @Test("The agent toggle asks Settings rather than deciding for itself")
    func toggleUsesTheRule() throws {
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/UI/SettingsView.swift"), encoding: .utf8)
        let start = try #require(text.range(of: "private func agentToggle"),
                                 "the agent toggle was renamed")
        let body = String(text[start.lowerBound...].prefix(1_500))
        #expect(body.contains("Settings.toggling"),
                "the toggle decides for itself again")
        #expect(body.contains(".disabled("),
                "a refused toggle is clickable, so the refusal is silent again")
        #expect(!body.contains("if !set.isEmpty"),
                "the rule the view used to enforce in silence is back")
    }

    /// A fixture that only records a good day proves the mapping can chart a
    /// number, not that it refuses one it cannot read — and refusing is the
    /// half that keeps an invented figure off the menu bar. Three shipped
    /// fixtures had no refusal case at all, so for those providers "a
    /// response this must not chart" was a claim with nothing behind it.
    ///
    /// Cheap to satisfy and impossible to satisfy accidentally: an empty
    /// envelope is a synthetic response, not a recorded one, so this asks for
    /// nothing a descriptor author has to obtain from a real account.
    @Test("Every quota fixture records a response the mapping must refuse")
    func fixturesCoverRefusal() throws {
        let directory = root.appendingPathComponent("Resources/quota-fixtures")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count >= 10, "no fixtures were scanned, so this proved nothing")

        for url in files {
            let document = try #require(
                JSONSerialization.jsonObject(with: try Data(contentsOf: url))
                    as? [String: Any],
                Comment(rawValue: "\(url.lastPathComponent) is not an object"))
            let cases = document["cases"] as? [[String: Any]]
                ?? [document].filter { $0["response"] != nil }
            #expect(cases.contains { $0["expectError"] != nil },
                    Comment(rawValue: "\(url.deletingPathExtension().lastPathComponent) "
                            + "records only responses that map, so nothing checks that it "
                            + "refuses one it cannot read"))
        }
    }

    /// The fixtures themselves must stay reachable from the test suite, not
    /// only from the command-line verifier — a fixture nobody replays is a
    /// recorded response and not a check.
    @Test("Quota fixtures are replayed by the suite as well as by the verifier")
    func fixturesAreReplayedInTests() throws {
        let descriptors = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Resources/harnesses"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try HarnessDocument.decode(Data(contentsOf: $0)).descriptor }
        var replayed = 0
        for descriptor in descriptors where descriptor.quota != nil {
            let report = QuotaFixture.verify(descriptor, in: AppResources.bundle)
            let found = try #require(report, Comment(rawValue:
                "\(descriptor.id) declares a quota block with no fixture to replay"))
            #expect(found.passed, Comment(rawValue: "\(descriptor.id): \(found.detail)"))
            replayed += 1
        }
        #expect(replayed >= 7, "expected every shipped quota descriptor; saw \(replayed)")
    }
}

/// A `DateFormatter` given an explicit `dateFormat` must be pinned to a fixed
/// locale. Without it the hour field follows the reader's own preferences: a
/// Mac with 24-Hour Time switched off renders `HH` as a twelve-hour clock
/// with no am/pm.
///
/// A source rule rather than a test run under another locale, because
/// `Locale.current` on macOS comes from user defaults and ignores the
/// environment — there is no `TZ` equivalent to set. This catches the mistake
/// where it is written instead.
@Suite("Fixed date formats are pinned to a fixed locale")
struct FixedDateFormatLocaleTests {

    @Test("Every fixed dateFormat is accompanied by en_US_POSIX")
    func fixedFormatsArePinned() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(sources.count > 10, "no sources were scanned, so this proved nothing")

        var checked = 0
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains(".dateFormat = \"") {
                checked += 1
                // The locale is set in the same initialiser; a dozen lines
                // either way covers every shape used here.
                let from = max(0, index - 12), to = min(lines.count, index + 12)
                let window = lines[from..<to].joined(separator: "\n")
                #expect(window.contains("en_US_POSIX"),
                        Comment(rawValue: "\(url.lastPathComponent):\(index + 1) sets a fixed "
                                + "dateFormat without pinning the locale"))
            }
        }
        #expect(checked >= 3, "expected the fixed-format formatters; saw \(checked)")
    }

    /// `Calendar.current` carries the reader's calendar *and* their zone, so a
    /// date built through it is a different instant for a different person.
    /// Every calendar here names an identifier; the one that resolves a reset
    /// date also pins UTC, because the same report must give the same instant
    /// wherever it is read.
    ///
    /// Added after the date-format rule missed this: that sweep looked only
    /// for `DateFormatter`, and a sweep is only as good as its pattern list.
    @Test("No calendar is taken from whoever is running the app")
    func calendarsAreExplicit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(sources.count > 10, "no sources were scanned, so this proved nothing")

        var calendars = 0
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("Calendar.current"),
                    Comment(rawValue: "\(url.lastPathComponent) takes the reader's calendar"))
            calendars += text.components(separatedBy: "Calendar(identifier:").count - 1
        }
        #expect(calendars >= 3, "expected the explicit calendars; saw \(calendars)")
    }
}

/// The caps written into TECHNICAL.md, checked against the constants they
/// describe. Documentation that states a number is a claim like any other,
/// and one nobody verifies drifts quietly — a reader trusting "64 windows"
/// after it became 16 is worse off than one who had to go and look.
@Suite("Documented limits are the limits")
struct DocumentedLimitTests {

    @Test("Every cap named in TECHNICAL.md matches the code")
    func capsMatchTheSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/TECHNICAL.md"),
                             encoding: .utf8)
        // Line breaks fall inside these phrases, so the text is flattened
        // first — the omission that hid one of them from a grep.
        let flat = doc.replacingOccurrences(of: "\n", with: " ")

        let expected: [(phrase: String, value: Int)] = [
            ("usage windows per response", DescriptorProvider.maxWindows),
            ("rows per remote host", RemoteTmux.maxRows),
            ("sessions per command harness", HarnessEngine.maxCommandSessions),
            ("cloud tasks per inventory", 2_000),
            ("rows per SQLite query", 2_000),
            ("files per file harness", 400),
        ]
        for (phrase, value) in expected {
            // Grouped by hand. `formatted()` follows the reader's region, and
            // on the machine this was written on that is Germany, so it
            // produced "2.000" and the check failed against a document that
            // was correct. The rule against locale-sensitive formatting,
            // broken inside the test that checks the rules.
            let plain = "\(value) \(phrase)"
            let grouped = value >= 1_000
                ? "\(value / 1_000),\(String(format: "%03d", value % 1_000)) \(phrase)"
                : plain
            #expect(flat.contains(plain) || flat.contains(grouped),
                    Comment(rawValue: "TECHNICAL.md does not say \(plain)"))
        }
    }

    /// The same rules applied to the tests. A locale-sensitive test passes on
    /// the machine that wrote it and fails on another, which is worse than a
    /// locale-sensitive source: it hides rather than misreports. One of these
    /// checks was itself written with `formatted()` and failed here, on a Mac
    /// whose region is Germany, against a document that was correct.
    @Test("No test formats through the reader's locale")
    func testsAreLocaleIndependent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tests = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Tests/AntariumTests"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(tests.count > 20, "no test sources were scanned")

        // Comments are skipped: several of these files explain a rule by
        // quoting the form it forbids.
        let banned = [".formatted(", "NumberFormatter", "Calendar.current"]
        for url in tests {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                // A form quoted in a string is this rule naming what it
                // forbids, not a use of it. Skipping the whole file instead
                // would have missed the `formatted()` that prompted this,
                // which was written here.
                for form in banned where trimmed.contains(form)
                    && !trimmed.contains("\"\(form)") {
                    Issue.record(Comment(rawValue: "\(url.lastPathComponent):\(index + 1) "
                                         + "uses \(form), which follows whoever runs it"))
                }
            }
        }
    }

    /// `Text("\(x)")` takes a `LocalizedStringKey`, which groups digits for
    /// the reader — 10259 rendered as "10.259" under a German locale, which
    /// is the bug recorded above `Fmt` and was still live in three places.
    /// `Text(verbatim:)` takes a String and does not.
    ///
    /// The rule covers every interpolation rather than the numeric ones,
    /// because which is which cannot be told from the source, and a rule that
    /// needs judgement to apply is one nobody applies.
    @Test("No SwiftUI Text interpolates into a localized key")
    func textInterpolationsAreVerbatim() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ui = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Sources/Antarium/UI"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(ui.count > 5, "no UI sources were scanned")
        for url in ui {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() where line.contains("Text(\"\\(")
                    // The comment above `Fmt` quotes the bad form to explain
                    // it; a rule that cannot tell prose from code makes the
                    // explanation unwritable.
                    && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let where_ = "\(url.lastPathComponent):\(index + 1)"
                Issue.record(Comment(rawValue: where_ + " interpolates into a localized "
                                     + "key; use Text(verbatim:)"))
            }
        }
    }

    /// And the numbers the prose quotes are the ones the code enforces, not
    /// merely numbers that appear in both places.
    @Test("The constants behind those phrases are what the readers use")
    func constantsAreTheOnesInForce() {
        #expect(DescriptorProvider.maxWindows == 64)
        #expect(RemoteTmux.maxRows == 256)
        #expect(HarnessEngine.maxCommandSessions == 256)
    }
}

/// Stop alerts depend on seeing an agent turn into `.ended`, and the
/// dashboard no longer shows that state. The order in `publish` is therefore
/// load-bearing: notice first, filter second. Swapping them leaves alerts
/// firing only for rows that vanish outright — a session that finishes
/// normally would stop being announced, and nothing else would look wrong.
///
/// A source rule because `publish` is private, drives AppKit, and the fault
/// is an order of calls rather than a value any function returns.
@Suite("Finished agents are noticed before they are hidden")
struct PublishOrderTests {

    @Test("noticeStops runs on the unfiltered rows")
    func noticeBeforeFilter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/Core/AgentStore.swift"), encoding: .utf8)
        let notice = try #require(source.range(of: "noticeStops(in: fresh,"),
                                  "noticeStops no longer takes the unfiltered rows")
        let filter = try #require(source.range(of: "Self.active(fresh)"),
                                  "publish no longer filters to active rows")
        #expect(notice.lowerBound < filter.lowerBound,
                "the rows are filtered before the stop is noticed, so finishing is silent")
    }
}

/// Every credentialled request goes through `UsageHTTP`.
///
/// `UsageHTTP.makeSession` attaches a delegate that caps the body at 2 MiB
/// and refuses a cross-host redirect, and `getJSON`/`postForm`/`postJSON`
/// register the per-task entry that delegate collects into. A provider that
/// builds its own `URLRequest` and calls `session.data(for:)` keeps the
/// session and loses the rest: `didReceive data:` returns at its first guard
/// because no entry exists, so the running-total cap enforces nothing, and a
/// refused redirect records its reason where nobody reads it.
///
/// ClaudeCodeProvider did exactly that, and it looked right — same session,
/// same `UsageHTTP.check`, same error mapping. Nothing but reading the two
/// paths side by side distinguishes them, which is what this replaces.
@Suite("Providers reach the network one way")
struct ProviderHTTPContractTests {

    private var sources: [(name: String, text: String)] {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            // Everything under Sources, recursively. This named two folders
            // and so covered neither the four files beside them nor the
            // eighteen in UI — a rule that lists its subjects covers only the
            // instances that prompted it, which is how two providers kept
            // claiming an agent was not installed after four surfaces
            // stopped.
            let files = FileManager.default.enumerator(
                at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            var out: [(String, String)] = []
            for url in files {
                // The two files that implement the bounded path are the ones
                // allowed to use the primitives it is built from.
                let name = url.lastPathComponent
                guard name != "UsageHTTP.swift", name != "BoundedResponse.swift"
                else { continue }
                out.append((name, try String(contentsOf: url, encoding: .utf8)))
            }
            return out.sorted { $0.0 < $1.0 }
        }
    }

    /// Lines that are prose rather than code. The comment on the fix quotes
    /// the form it replaced, and a rule that cannot tell the two apart makes
    /// explaining a mistake impossible.
    private func isCode(_ line: Substring) -> Bool {
        !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    @Test("No provider builds its own session or reads a body outside UsageHTTP",
          arguments: ["URLSession(", "URLSession.shared", ".data(for:", ".data(from:",
                      ".bytes(for:", ".bytes(from:", "dataTask(with:"])
    func noHandRolledTransport(_ forbidden: String) throws {
        let files = try sources
        // Above what the two folders this used to name contain, so the
        // threshold fails if the scope is narrowed back rather than passing
        // either way — which the first number written here would have.
        #expect(files.count > 70, "only \(files.count) sources were scanned")
        for file in files {
            for (index, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() where isCode(line) && line.contains(forbidden) {
                Issue.record(Comment(rawValue:
                    "\(file.name):\(index + 1) uses \(forbidden) — the bounded body "
                    + "and the redirect refusal are in UsageHTTP, not in the session"))
            }
        }
    }

    /// The positive half. A provider that talks to the network has to get its
    /// session from the one place that configures it, and there must be some
    /// — a rule nothing satisfies passes for the wrong reason.
    @Test("Every session a provider holds comes from UsageHTTP.makeSession")
    func sessionsComeFromUsageHTTP() throws {
        var holders: [String] = []
        for file in try sources {
            // Naming URLSession at all, outside the two files that implement
            // the bounded path, is how a second transport would start.
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated()
            where isCode(line) && line.contains("URLSession") {
                Issue.record(Comment(rawValue:
                    "\(file.name):\(index + 1) names URLSession outside UsageHTTP"))
            }
            if file.text.contains("UsageHTTP.makeSession") { holders.append(file.name) }
        }
        #expect(holders.count >= 5,
                Comment(rawValue: "only \(holders.count) sources hold a configured session: "
                        + holders.joined(separator: ", ")))
    }
}

/// What a provider hands the menu bar, bounded whatever the provider forgot.
///
/// Five of the nine native providers clamped their response text and four did
/// not: Codex put `limit_name` straight into a menu item, bounded only by the
/// 2 MiB body cap. The per-provider clamps are the policy — 64 characters for
/// network text, and a descriptor's own labels left exactly as their author
/// wrote them, because local configuration is trusted and a response is not.
/// These are the floor under both.
@Suite("A gauge cannot carry a response into the menu bar")
struct GaugeBoundsTests {

    @Test("A title the size of a response body is cut to the backstop")
    func titleIsBounded() {
        let huge = String(repeating: "T", count: 200_000)
        let gauge = Gauge(id: huge, badge: huge, title: huge, used: 0.5)
        #expect(gauge.title.count == Gauge.maxTitle)
        #expect(gauge.badge.count == Gauge.maxBadge)
        #expect(gauge.id.count == Gauge.maxTitle)
    }

    /// The backstop must not overrule an author. A descriptor's label is
    /// trusted local configuration, and the shipped harnesses' own strings
    /// are eleven characters at the longest — anything a person would write
    /// has to pass through untouched.
    @Test("An authored title passes through unchanged")
    func authoredTitleSurvives() {
        let written = String(repeating: "A sensibly long window name. ", count: 10)
        #expect(written.count < Gauge.maxTitle)
        #expect(Gauge(id: "w", badge: "5H", title: written, used: 0).title == written)
    }

    /// A provider computing a fraction from two response numbers can divide
    /// by zero. NaN compares false against every bound, so it would pass the
    /// clamps elsewhere and paint a meter that never moves; infinity paints a
    /// full one. Neither is a usage figure.
    @Test("A figure that is not a number is zero, not a painted meter",
          arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteUsedIsZero(_ value: Double) {
        let gauge = Gauge(id: "w", badge: "5H", title: "Window", used: value)
        #expect(gauge.used == 0)
        #expect(gauge.remaining == 1)
        #expect(gauge.usedPercentText == Gauge.percentText(0))
    }

    @Test("A window length that is not a number is absent, not a sort key")
    func nonFiniteWindowIsAbsent() {
        let gauge = Gauge(id: "w", badge: "5H", title: "Window", used: 0.5,
                          windowSeconds: .nan)
        #expect(gauge.windowSeconds == nil,
                "a NaN window seconds sorts unpredictably against every other row")
    }

    @Test("An ordinary figure is untouched")
    func ordinaryFigureSurvives() {
        let gauge = Gauge(id: "w", badge: "5H", title: "Window", used: 0.42,
                          windowSeconds: 18_000)
        #expect(gauge.used == 0.42)
        #expect(gauge.windowSeconds == 18_000)
    }
}

/// A provider owns a URLSession, and a session with a delegate stays alive
/// until something invalidates it.
///
/// Nothing did. Editing a harness file changes its signature, the registry
/// builds a replacement provider, and the old one was dropped holding a live
/// session, a live delegate, and an entry in `UsageHTTP.readers` that nothing
/// removed. Ordinary use — a contributor with the JSON open — grew the app a
/// session at a time, and no test could see it because every other thing
/// about the replacement was right.
@Suite("Replaced providers let their sessions go", .serialized)
struct ProviderSessionReleaseTests {

    /// A descriptor with a quota block, so the registry builds a provider for
    /// it, and `token` so the signature moves when we want it to.
    private func descriptor(id: String, endpoint: String) throws -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1, "id": id, "name": "Release \(id)",
            "process": [:], "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": endpoint,
                      "credential": ["kind": "env", "name": "RELEASE_TEST_TOKEN"],
                      "windows": ["list": "data", "usedPercent": "pct"]]]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    /// Waits for the session's own queue to finish invalidating, which does
    /// not happen synchronously with the call that asked for it.
    private func released(_ provider: DescriptorProvider) -> Bool {
        for _ in 0..<60 where provider.sessionIsTracked { usleep(50_000) }
        return !provider.sessionIsTracked
    }

    private func build(_ descriptor: HarnessDescriptor) throws -> DescriptorProvider {
        try #require(ProviderRegistry.providers(from: [descriptor]).first
                     as? DescriptorProvider)
    }

    /// Rebuilding with the same descriptor keeps the same provider and the
    /// same session — the baseline, and the thing a release must not break.
    @Test("An unchanged descriptor keeps its provider and its session")
    func unchangedDescriptorIsStable() throws {
        let one = try descriptor(id: "release-stable", endpoint: "https://example.invalid/a")
        let first = try build(one)
        for _ in 0..<5 {
            #expect(try build(one) === first, "an unchanged descriptor was rebuilt")
        }
        #expect(first.sessionIsTracked, "a live provider lost its session")
        _ = ProviderRegistry.providers(from: [])
        #expect(released(first))
    }

    /// The one that was leaking. Each edit is a new signature and a new
    /// provider; without a release each is also a session that never goes.
    @Test("Editing a descriptor releases the provider it replaced")
    func editingReleasesTheOldOne() throws {
        var previous: DescriptorProvider?
        var abandoned: [DescriptorProvider] = []
        for i in 0..<5 {
            let edited = try descriptor(id: "release-edited",
                                        endpoint: "https://example.invalid/v\(i)")
            let provider = try build(edited)
            if let previous {
                #expect(provider !== previous, "an edited descriptor was not rebuilt")
                abandoned.append(previous)
            }
            previous = provider
        }
        for old in abandoned {
            #expect(released(old), "an edit left its predecessor's session behind")
        }
        #expect(previous?.sessionIsTracked == true, "the current provider lost its session")
        _ = ProviderRegistry.providers(from: [])
    }

    /// A descriptor that goes away is the other half: its provider is dropped
    /// from the cache, and dropping it is not releasing it.
    @Test("A descriptor that disappears takes its session with it")
    func removedDescriptorIsReleased() throws {
        let gone = try descriptor(id: "release-gone", endpoint: "https://example.invalid/g")
        let provider = try build(gone)
        #expect(provider.sessionIsTracked)
        _ = ProviderRegistry.providers(from: [])
        #expect(released(provider), "a removed descriptor kept its session")
    }
}

/// Waking refreshes both readings the bar shows.
///
/// A menu bar carries two pictures of the same moment: the quota gauges and
/// the agent rows. Only the gauges were refreshed when the machine woke. The
/// rows waited for their next tick, and `agentScanSeconds` is configurable up
/// to ten minutes — so after a lid had been shut overnight the bar could
/// report agents that had not existed for hours, beside gauges that were
/// current. Stale beside fresh is worse than both being a moment late,
/// because only one of them looks wrong.
@Suite("Waking refreshes the rows as well as the gauges")
struct WakeRefreshContractTests {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("The wake handler refreshes both the items and the store")
    func wakeTouchesBoth() throws {
        let text = try source("Sources/Antarium/AppController.swift")
        let handler = try #require(text.range(of: "func didWake()"),
                                   "there is no wake handler any more")
        let body = text[handler.lowerBound...].prefix(400)
        #expect(body.contains("items.forEach"), "waking stopped refreshing the gauges")
        #expect(body.contains("AgentStore.shared.wake()"),
                "waking refreshes the gauges and leaves the rows stale")
    }

    /// And the store's own wake does both halves: a refresh with the timer
    /// left where it was fires again almost immediately, which is a scan
    /// nobody asked for.
    @Test("The store's wake reschedules as well as refreshing")
    func storeWakeReschedules() throws {
        let text = try source("Sources/Antarium/Core/AgentStore.swift")
        let wake = try #require(text.range(of: "func wake() {"))
        let body = text[wake.lowerBound...].prefix(120)
        #expect(body.contains("reschedule()"), "the next tick keeps the old phase")
        #expect(body.contains("refresh()"), "waking no longer refreshes")
    }

    /// A forced refresh would bypass the remote sweep's minimum interval, and
    /// a lid opened and closed a few times would become a burst of SSH.
    @Test("Waking does not force the remote sweep")
    func wakeDoesNotForceRemote() throws {
        let text = try source("Sources/Antarium/Core/AgentStore.swift")
        let wake = try #require(text.range(of: "func wake() {"))
        let body = text[wake.lowerBound...].prefix(120)
        #expect(!body.contains("force: true"),
                "waking forces a remote sweep past its own throttle")
    }
}

/// One sound for a sweep, not one per row.
///
/// The sound means "something finished". A fleet finishing together played
/// one copy per agent, over each other — which says nothing twenty times, and
/// is the audible half of the same problem the banner limit fixes.
@Suite("A sweep makes one sound")
struct StopSoundContractTests {

    @Test("The stop sound is played once per sweep, outside the loop")
    func soundIsOutsideTheLoop() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/Core/AgentStore.swift"), encoding: .utf8)
        let notice = try #require(text.range(of: "private func noticeStops("))
        let body = String(text[notice.lowerBound...].prefix(900))

        // Line by line, not by position. Comparing the offsets of the first
        // occurrence of each passed when the sound was put *inside* the loop
        // line — it still came after the words "for row in finished", and the
        // mutation that did exactly that survived.
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let playing = lines.filter { $0.contains("Sounds.play(.agentStopped)") }
        #expect(playing.count == 1,
                "the stop sound is played from \(playing.count) places in one sweep")
        let line = try #require(playing.first)
        #expect(!line.contains("for row in"),
                "the sound is inside the loop again, one per agent")
        #expect(line.contains("if !finished.isEmpty"),
                "a sweep where nothing finished still makes a sound")
        #expect(lines.contains { $0.contains("for row in finished") },
                "the banners are no longer posted per row")
    }
}

/// The SDK can express every quota shape the runtime reads.
///
/// The round-trip above covers a session harness and does not touch quota at
/// all, so three fields added to both sides over the last few days were never
/// carried from one to the other by a test. That is the same alignment rule
/// that let `--check` call a working field ignored, one surface along: a
/// contributor writes a descriptor with the SDK, and anything it cannot say
/// is a thing they cannot declare however well the runtime reads it.
@Suite("The SDK can say what the runtime reads")
struct SDKQuotaAlignmentTests {

    private func config(_ build: (inout HarnessConfig) -> Void) throws -> HarnessDescriptor {
        var config = HarnessConfig(
            id: "sdk-quota", name: "SDK Quota", match: ["/sdk-quota"],
            source: .init(kind: .none, path: ""),
            map: .init(cwd: "cwd"))
        build(&config)
        return try HarnessDocument.decode(try config.encoded()).descriptor
    }

    private var windows: HarnessConfig.Quota.Windows {
        .init(list: "data")
    }

    /// The endpoint form, which every shipped quota descriptor uses.
    @Test("An endpoint quota survives the round trip")
    func endpointQuota() throws {
        let runtime = try config {
            var quota = HarnessConfig.Quota(endpoint: "https://example.invalid/u",
                                            windows: windows)
            quota.windows.usedPercent = "pct"
            $0.quota = quota
        }
        #expect(runtime.quota?.endpoint == "https://example.invalid/u")
        #expect(runtime.quota?.resolvedMethod == .get)
        #expect(runtime.quota?.command == nil)
    }

    /// The command form, for a service that has stopped answering over HTTP.
    @Test("A command quota survives the round trip")
    func commandQuota() throws {
        let runtime = try config {
            var quota = HarnessConfig.Quota(command: "agy", args: ["-p", "/usage"],
                                            windows: windows)
            quota.windows.usedPercent = "pct"
            $0.quota = quota
        }
        #expect(runtime.quota?.command == "agy")
        #expect(runtime.quota?.args == ["-p", "/usage"])
        #expect(runtime.quota?.endpoint == nil)
    }

    /// The posted form, for a service whose usage call is not a GET.
    @Test("A posted quota survives the round trip")
    func postedQuota() throws {
        let runtime = try config {
            var quota = HarnessConfig.Quota(endpoint: "https://example.invalid/u",
                                            windows: windows)
            quota.windows.usedPercent = "pct"
            quota.method = "POST"
            quota.body = ["scope": "current"]
            $0.quota = quota
        }
        #expect(runtime.quota?.resolvedMethod == .post)
        #expect(runtime.quota?.body == ["scope": "current"])
    }

    /// And the capability suffix filter, added to both sides in the same week
    /// and likewise never carried across by anything.
    @Test("A suffix-filtered capability survives the round trip")
    func suffixFilteredCapability() throws {
        let runtime = try config {
            var rule = HarnessConfig.CapabilityRule(probe: .content,
                                                    project: [".github/instructions"])
            rule.fileSuffixes = [".instructions.md"]
            $0.capabilities = ["instruction": rule]
        }
        #expect(runtime.capabilityRules["instruction"]?.countedSuffixes == [".instructions.md"])
    }
}


/// A migrated document is still one the runtime reads.
///
/// The SDK's own tests check that migration keeps what it does not
/// recognise; they cannot check that what comes out still decodes, because
/// that file deliberately imports only the SDK. This is the other half, in
/// the place where both are in scope — preservation achieved by producing
/// something unreadable would be no preservation at all.
@Suite("A migrated descriptor still decodes")
struct MigratedDocumentDecodesTests {

    @Test("A v0 file carrying a field newer than the migration still loads")
    func migratedDocumentStillDecodes() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 0, "id": "old", "name": "Old",
            "match": ["/old"], "matchProcessName": ["old"],
            "source": ["kind": "none", "path": ""],
            "quota": ["command": "agy",
                      "windows": ["list": "data", "usedPercent": "pct"]],
        ])
        let migrated = try HarnessConfigMigration.migrate(data)
        let descriptor = try HarnessDocument.decode(migrated.data).descriptor
        #expect(descriptor.quota?.command == "agy")
        #expect(descriptor.processRule.pathContains?.contains("/old") == true)
        #expect(descriptor.processRule.names?.contains("old") == true)
    }
}
