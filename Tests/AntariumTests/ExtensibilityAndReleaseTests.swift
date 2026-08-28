import AppKit
import Foundation
import SQLite3
import SwiftUI
import Testing
import AntariumHarnessSDK
@testable import Antarium

@Suite("Extensible harness format", .serialized)
struct ExtensibilityAndReleaseTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antarium-extensibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("The SDK emits the current semantic format and declarative process rules")
    func sdkOwnsFormatAndProcessConfiguration() throws {
        var config = HarnessConfig(
            id: "future-agent",
            name: "Future Agent",
            process: .init(pathContains: ["/Future.app/"],
                           names: ["future-agent"],
                           argv0Contains: ["future-cli"]),
            source: .init(kind: .none, path: ""))
        config.presentation = .init(mark: "future", fallbackName: "Future session")

        let data = try config.encoded()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["formatVersion"] as? Int == HarnessConfig.currentFormatVersion)
        #expect(object["process"] as? [String: Any] != nil)
        #expect(object["match"] == nil, "New SDK documents must not emit legacy process fields")

        let decoded = try HarnessDocument.decode(data)
        #expect(decoded.descriptor.formatVersion == HarnessDocument.currentVersion)
        #expect(decoded.descriptor.presentation?.mark == "future")
    }

    @Test("Unversioned documents migrate in memory without changing their meaning")
    func legacyMigrationPreservesMeaning() throws {
        let legacy = Data(#"""
        {
          "id":"legacy","name":"Legacy","match":["/legacy/"],
          "matchProcessName":["legacy"],"fallbackName":"Old session","mark":"old",
          "source":{"kind":"none","path":""}
        }
        """#.utf8)

        let result = try HarnessDocument.decode(legacy)
        #expect(result.migratedFrom == 0)
        #expect(result.descriptor.formatVersion == HarnessDocument.currentVersion)
        #expect(result.descriptor.match == ["/legacy/"])
        #expect(result.descriptor.processNames == ["legacy"])
        #expect(result.descriptor.presentation?.fallbackName == "Old session")

        let migrated = try HarnessDocument.migratedData(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        #expect(object["formatVersion"] as? Int == HarnessDocument.currentVersion)
        #expect(object["process"] as? [String: Any] != nil)
        #expect(object["presentation"] as? [String: Any] != nil)
        #expect(object["match"] == nil)
    }

    @Test("A newer semantic format is rejected rather than guessed")
    func futureFormatFailsClosed() throws {
        let data = Data(#"""
        {
          "formatVersion":999,"id":"future","name":"Future",
          "process":{},"source":{"kind":"none","path":""}
        }
        """#.utf8)
        #expect(throws: HarnessDocument.Error.self) {
            _ = try HarnessDocument.decode(data)
        }
    }

    @Test("Current documents must satisfy required semantic sections")
    func currentFormatCannotUseLegacyShape() {
        let data = Data(#"{"formatVersion":1,"id":"bad","name":"Bad","match":["/bad"],"source":{"kind":"none","path":""}}"#.utf8)
        #expect(throws: HarnessDocument.Error.self) {
            _ = try HarnessDocument.decode(data)
        }
    }

    @Test("Third-party authors can migrate documents without importing the app")
    func sdkExposesMigration() throws {
        let legacy = Data(#"{"id":"sdk-old","name":"Old","match":["/old"],"source":{"kind":"none","path":""}}"#.utf8)
        let migration = try HarnessConfigMigration.migrate(legacy)
        #expect(migration.migratedFrom == 0)
        let object = try #require(JSONSerialization.jsonObject(with: migration.data)
            as? [String: Any])
        #expect(object["formatVersion"] as? Int == HarnessConfig.currentFormatVersion)
        #expect(object["process"] as? [String: Any] != nil)
    }

    @Test("Path, name and argv process evidence are all configuration")
    func processEvidenceIsDeclarative() throws {
        let data = Data(#"""
        {
          "formatVersion":1,"id":"process","name":"Process",
          "process":{"pathContains":["/Agent.app/"],"names":["agentd"],"argv0Contains":["agent-cli"]},
          "source":{"kind":"none","path":""}
        }
        """#.utf8)
        let descriptor = try HarnessDocument.decode(data).descriptor

        #expect(descriptor.claims(.init(pid: 1, ppid: 0, path: "/x/Agent.app/run",
                                        name: "run", argv0: "run", rss: 0)))
        #expect(descriptor.claims(.init(pid: 2, ppid: 0, path: "/usr/bin/node",
                                        name: "agentd", argv0: "node", rss: 0)))
        #expect(descriptor.claims(.init(pid: 3, ppid: 0, path: "/usr/bin/node",
                                        name: "node", argv0: "/opt/agent-cli", rss: 0)))
    }

    @Test("An open source file binds simultaneous same-folder processes to distinct sessions")
    func processOpenFileBindingIsDeclarativeAndExact() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workingFile = root.appendingPathComponent("working.jsonl")
        let waitingFile = root.appendingPathComponent("waiting.jsonl")

        func transcript(id: String, status: String) -> Data {
            Data((#"{"type":"session_meta","timestamp":"2026-08-26T10:00:00Z","payload":{"originator":"fixture","cwd":"/fixture/shared","session_id":"\#(id)"}}"#
                + "\n"
                + #"{"type":"event_msg","timestamp":"2026-08-26T10:01:00Z","payload":{"type":"\#(status)"}}"#
                + "\n").utf8)
        }
        try transcript(id: "working", status: "task_started").write(to: workingFile)
        try transcript(id: "waiting", status: "task_complete").write(to: waitingFile)

        let descriptorData = Data("""
        {
          "formatVersion":1,"id":"bound","name":"Bound",
          "process":{"pathContains":["/agent"],"sessionBinding":"openSourceFile"},
          "source":{"kind":"jsonl","path":"\(root.path)","glob":"*.jsonl",
            "filter":{"payload.originator":["fixture"]}},
          "map":{"cwd":"payload.cwd","sessionID":"payload.session_id",
            "timestamp":"timestamp","status":{"field":"payload.type",
              "working":["task_started"],"idle":["task_complete"]}}
        }
        """.utf8)
        let descriptor = try HarnessDocument.decode(descriptorData).descriptor

        let sdkProcess = HarnessConfig.ProcessRule(
            pathContains: ["/agent"], sessionBinding: .openSourceFile)
        #expect(sdkProcess.sessionBinding == .openSourceFile)
        #expect(descriptor.processRule.sessionBinding == .openSourceFile)
        let sdkDocument = HarnessConfig(
            id: "bound-sdk", name: "Bound SDK", process: sdkProcess,
            source: .init(kind: .jsonl, path: "/fixture", glob: "*.jsonl"))
        let sdkObject = try #require(JSONSerialization.jsonObject(
            with: sdkDocument.encoded()) as? [String: Any])
        let encodedProcess = try #require(sdkObject["process"] as? [String: Any])
        #expect(encodedProcess["sessionBinding"] as? String == "openSourceFile")

        let invalidBinding = Data(#"{"formatVersion":1,"id":"bad","name":"Bad","process":{"sessionBinding":"openSourceFile"},"source":{"kind":"none","path":""}}"#.utf8)
        #expect(throws: HarnessDocument.Error.self) {
            _ = try HarnessDocument.decode(invalidBinding)
        }
        let invalidSDK = HarnessConfig(
            id: "bad-sdk", name: "Bad SDK", process: sdkProcess,
            source: .init(kind: .none, path: ""))
        #expect(throws: HarnessConfig.ValidationError.self) {
            _ = try invalidSDK.encoded()
        }

        let openHandle = try FileHandle(forReadingFrom: workingFile)
        defer { try? openHandle.close() }
        let observedOpenFiles = Processes.openFilePaths(
            of: Int32(ProcessInfo.processInfo.processIdentifier)).map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            }
        #expect(observedOpenFiles.contains(workingFile.resolvingSymlinksInPath().path))

        HarnessEngine.resetCaches(includingParsedFiles: true)
        let working = HarnessEngine.session(descriptor,
                                            boundToOpenFiles: [workingFile.path])
        let waiting = HarnessEngine.session(descriptor,
                                            boundToOpenFiles: [waitingFile.path])
        let unrelated = HarnessEngine.session(descriptor,
                                              boundToOpenFiles: [root.appendingPathComponent("other.txt").path])

        #expect(working?.sessionID == "working")
        #expect(working?.isWorking == true)
        #expect(waiting?.sessionID == "waiting")
        #expect(waiting?.isWorking == false)
        #expect(unrelated == nil)
    }

    @Test("Open-tab evidence can come from SQLite")
    func sqliteTabSelectionIsConfiguration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ui.sqlite").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        guard let database else { return }
        #expect(sqlite3_exec(database,
            "CREATE TABLE tabs (session TEXT, open INTEGER);"
            + "INSERT INTO tabs VALUES ('one',1),('closed',0),('two',1);",
            nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        let data = Data("""
        {
          "formatVersion":1,"id":"sql-tabs","name":"SQL tabs","process":{},
          "source":{"kind":"none","path":""},
          "selection":{"kind":"sqlite","path":"\(path)",
            "query":"SELECT session FROM tabs WHERE open = 1","column":"session"}
        }
        """.utf8)
        let descriptor = try HarnessDocument.decode(data).descriptor
        #expect(SessionSelection.openIDs(descriptor.sessionSelection) == ["one", "two"])
    }

    @Test("Open-tab evidence can come from a JSON command")
    func commandTabSelectionIsConfiguration() throws {
        let data = Data(#"""
        {
          "formatVersion":1,"id":"command-tabs","name":"Command tabs","process":{},
          "source":{"kind":"none","path":""},
          "selection":{"kind":"command","command":"/bin/sh",
            "args":["-c","printf '[{\"id\":\"live\",\"open\":true},{\"id\":\"closed\",\"open\":false}]'"],
            "id":"id","filter":{"open":["true"]}}
        }
        """#.utf8)
        let descriptor = try HarnessDocument.decode(data).descriptor
        #expect(SessionSelection.openIDs(descriptor.sessionSelection) == ["live"])
    }
}

@Suite("Truthful harness evaluations", .serialized)
struct HarnessEvaluationTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antarium-evaluation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func descriptor(root: URL, id: String) throws -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1,
            "id": id, "name": "Evaluation", "process": [:],
            "source": ["kind": "jsonl", "path": root.path, "glob": "session.jsonl"],
            "map": ["sessionID": "id", "inputTokens": "usage.input",
                    "outputTokens": "usage.output", "turnWhere": ["type": "message"]],
        ]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    @Test("Cold, warm and append evaluations report exact work")
    func exactIncrementalMetrics() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let initial = (0..<1_000).map {
            #"{"id":"s","type":"message","usage":{"input":1,"output":2},"n":\#($0)}"#
        }.joined(separator: "\n") + "\n"
        try Data(initial.utf8).write(to: file)
        let value = try descriptor(root: root, id: "metrics-\(UUID().uuidString)")

        HarnessEngine.resetCaches(includingParsedFiles: true)
        let cold = HarnessEngine.evaluate(value)
        #expect(cold.sessions.first?.inputTokens == 1_000)
        #expect(cold.sessions.first?.outputTokens == 2_000)
        #expect(cold.metrics.sourceBytes == UInt64(Data(initial.utf8).count))
        #expect(cold.metrics.bytesRead == cold.metrics.sourceBytes)
        #expect(cold.metrics.recordsParsed == 1_000)
        #expect(cold.metrics.cacheHit == false)

        let warm = HarnessEngine.evaluate(value)
        #expect(warm.metrics.bytesRead == 0)
        #expect(warm.metrics.recordsParsed == 0)
        #expect(warm.metrics.cacheHit == true)

        let appended = #"{"id":"s","type":"message","usage":{"input":7,"output":11}}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let incremental = HarnessEngine.evaluate(value)
        #expect(incremental.sessions.first?.inputTokens == 1_007)
        #expect(incremental.sessions.first?.outputTokens == 2_011)
        #expect(incremental.metrics.bytesRead == UInt64(Data(appended.utf8).count))
        #expect(incremental.metrics.recordsParsed == 1)
        #expect(incremental.metrics.cacheHit == false)
    }

    @Test("The standard cold-scan CI budget is explicit and generous")
    func generatedTranscriptPerformanceBudget() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let count = 20_000
        let line = #"{"id":"s","type":"message","usage":{"input":1,"output":1}}"# + "\n"
        try Data(String(repeating: line, count: count).utf8).write(to: file)
        let value = try descriptor(root: root, id: "budget-\(UUID().uuidString)")

        HarnessEngine.resetCaches(includingParsedFiles: true)
        let result = HarnessEngine.evaluate(value)
        #expect(result.metrics.recordsParsed == count)
        #expect(result.metrics.elapsedMilliseconds < HarnessPerformanceBudget.coldJSONLMilliseconds,
                "Cold JSONL evaluation exceeded the documented CI guardrail")
    }

    @Test("Every bundled data-backed harness has a passing, dated fixture")
    func bundledCompatibilityFixturesPass() throws {
        let urls = AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses") ?? []
        for url in urls {
            let descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            guard descriptor.source.kind != .none else { continue }
            let report = HarnessCompatibility.verifyFixture(descriptor, in: AppResources.bundle)
            #expect(report.status == .fixtureVerified,
                    "\(descriptor.id): \(report.detail)")
            #expect(report.verifiedAt != nil)
            #expect(report.expected == report.actual,
                    "\(descriptor.id) fixture numbers differ")
        }
    }
}

@Suite("UI and release contracts", .serialized)
struct UIAndReleaseContractTests {
    @Test("Harness rows expose status and source to assistive technology")
    func accessibleHarnessPresentation() throws {
        let data = Data(#"""
        {
          "formatVersion":1,"id":"accessible","name":"Accessible Agent",
          "process":{},"source":{"kind":"sqlite","path":"/tmp/x",
            "query":"SELECT id FROM sessions","columns":["sessionID"]},
          "compatibility":{"level":"fixtureVerified","verifiedAt":"2026-08-25",
            "fixture":"harness-fixtures/accessible.json"}
        }
        """#.utf8)
        let descriptor = try HarnessDocument.decode(data).descriptor
        let row = HarnessRowPresentation(descriptor: descriptor, edited: true,
                                         compatibilityStatus: .fixtureVerified)
        #expect(row.sourceLabel == "SQLite")
        #expect(row.compatibilityLabel == "Fixture verified")
        #expect(row.accessibilityLabel.contains("Accessible Agent"))
        #expect(row.accessibilityLabel.contains("SQLite"))
        #expect(row.accessibilityLabel.contains("edited"))
    }

    @MainActor @Test("Settings has a renderable deterministic snapshot surface")
    func settingsSnapshotRenders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antarium-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("settings.png")
        #expect(Diagnostics.writeThemeSheet(SettingsView(model: SettingsModel()),
                                            to: output.path))
        let image = try #require(NSImage(contentsOf: output))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @MainActor @Test("Menu gauges render their light and dark state matrix")
    func menuStateSnapshotRenders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antarium-menu-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("menu-states.png")
        #expect(Preview.write(to: output.path))
        let image = try #require(NSImage(contentsOf: output))
        #expect(image.size.width > 500, "The sheet must contain both appearances")
        #expect(image.size.height > 250, "The sheet must contain the complete state matrix")
    }

    @Test("The status menu is laid out once before AppKit starts tracking it")
    func statusMenuIsNotStructurallyRebuiltWhileOpen() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/AgentItem.swift"), encoding: .utf8)
        let rebuildCalls = source.components(separatedBy: "        rebuildMenu()\n").count - 1

        #expect(source.contains("private func showMenu() {\n        rebuildMenu()"))
        #expect(rebuildCalls == 1,
                "Reinserting NSMenu items during tracking leaves later rows with zero-sized frames")
        #expect(!source.contains("if menuIsOpen { rebuildMenu() }"),
                "An in-flight refresh must not replace rows while AppKit is tracking the menu")
    }

    @Test("Public provider errors use the current product name")
    func publicProviderErrorsUseCurrentBranding() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let provider = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/Providers/ClaudeCodeProvider.swift"), encoding: .utf8)
        #expect(!provider.contains("AgentGauge"))
        #expect(provider.contains("Antarium can't read Claude Code's Keychain item."))
    }

    @Test("The dashboard is read-only with respect to external sessions and processes")
    func dashboardCannotTerminateExternalWork() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dashboard = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/UI/Dashboard.swift"), encoding: .utf8)
        let focus = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/Core/Focus.swift"), encoding: .utf8)

        #expect(!dashboard.contains("Kill tmux Session"))
        #expect(!dashboard.contains("Quit Agent"))
        #expect(!dashboard.contains("kill(pid"))
        #expect(!focus.contains("killTmux"))
        #expect(!focus.contains("\"kill-session\""))
    }

    @Test("Bundled harness commands are an explicit read-only allowlist")
    func bundledHarnessCommandsAreAudited() throws {
        let urls = AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses") ?? []
        var commands: [String] = []
        for url in urls {
            let descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            if descriptor.source.kind == .command, let command = descriptor.source.command {
                commands.append("\(descriptor.id):source \(([command] + (descriptor.source.args ?? [])).joined(separator: " "))")
            }
            if let selection = descriptor.sessionSelection,
               selection.kind == .command, let command = selection.command {
                commands.append("\(descriptor.id):selection \(([command] + (selection.args ?? [])).joined(separator: " "))")
            }
            if let credential = descriptor.quota?.credential,
               credential.kind == "command", let command = credential.command {
                commands.append("\(descriptor.id):credential \(([command] + (credential.args ?? [])).joined(separator: " "))")
            }
        }

        #expect(commands.sorted() == ["copilot:credential gh auth token"])
    }

    @Test("The public repository uses the standard MIT license")
    func publicLicenseIsMIT() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let license = try String(contentsOf: root.appendingPathComponent("LICENSE"),
                                 encoding: .utf8)
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"),
                                encoding: .utf8)
        let readmeWords = readme.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")

        #expect(license.hasPrefix("MIT License"))
        #expect(license.contains("Copyright (c) 2026 eppser"))
        #expect(license.contains("Permission is hereby granted, free of charge"))
        #expect(license.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
        #expect(readme.contains("MIT License"))
        #expect(!readmeWords.contains("Commercial use requires a separate license"))
    }

    @Test("Public docs explain ecosystem position and runtime architecture")
    func publicDocsExplainPositionAndArchitecture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"),
                                encoding: .utf8)
        let technical = try String(
            contentsOf: root.appendingPathComponent("docs/TECHNICAL.md"), encoding: .utf8)
        let ecosystem = try String(
            contentsOf: root.appendingPathComponent("docs/ECOSYSTEM.md"), encoding: .utf8)

        #expect(readme.contains("## Where Antarium fits"))
        #expect(readme.contains("## How Antarium works"))
        #expect(readme.contains("```mermaid"))
        #expect(technical.contains("## Runtime data flow"))
        #expect(technical.contains("generation-gated"))
        #expect(ecosystem.contains("Conductor"))
        #expect(ecosystem.contains("Zen"))
        #expect(ecosystem.contains("does not currently ship a dedicated"))
    }

    @Test("Release automation is syntax-valid and supports signed notarized archives")
    func releasePipelineContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"),
                                  encoding: .utf8)
        let script = try String(contentsOf: root.appendingPathComponent("build.sh"),
                                encoding: .utf8)
        #expect(manifest.contains("optionalGeneratedExcludes"))
        #expect(manifest.contains("fileExists(atPath:"))
        #expect(script.contains("--notarize"))
        #expect(script.contains("NOTARY_PROFILE"))
        #expect(script.contains("notarytool submit"))
        #expect(script.contains("stapler staple"))
        #expect(script.contains("spctl --assess"))
        #expect(script.contains("SHA256"))
    }
}
