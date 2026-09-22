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
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
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

        HarnessEngine.resetCaches()
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
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let initial = (0..<1_000).map {
            #"{"id":"s","type":"message","usage":{"input":1,"output":2},"n":\#($0)}"#
        }.joined(separator: "\n") + "\n"
        try Data(initial.utf8).write(to: file)
        let value = try descriptor(root: root, id: "metrics-\(UUID().uuidString)")

        HarnessEngine.resetCaches()
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
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let count = 20_000
        let line = #"{"id":"s","type":"message","usage":{"input":1,"output":1}}"# + "\n"
        try Data(String(repeating: line, count: count).utf8).write(to: file)
        let value = try descriptor(root: root, id: "budget-\(UUID().uuidString)")

        HarnessEngine.resetCaches()
        let result = HarnessEngine.evaluate(value)
        #expect(result.metrics.recordsParsed == count)
        #expect(result.metrics.elapsedMilliseconds < HarnessPerformanceBudget.coldJSONLMilliseconds,
                "Cold JSONL evaluation exceeded the documented CI guardrail")
    }

    @Test("Every bundled data-backed harness has a passing, dated fixture")
    func bundledCompatibilityFixturesPass() throws {
        HarnessEngineTestIsolation.lock.lock()
        defer { HarnessEngineTestIsolation.lock.unlock() }
        let urls = AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses") ?? []
        var checked = 0
        for url in urls {
            let descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            guard descriptor.source.kind != .none else { continue }
            checked += 1
            let report = HarnessCompatibility.verifyFixture(descriptor, in: AppResources.bundle)
            #expect(report.status == .fixtureVerified,
                    "\(descriptor.id): \(report.detail)")
            #expect(report.verifiedAt != nil)
            #expect(report.expected == report.actual,
                    "\(descriptor.id) fixture numbers differ")
        }
        // Every assertion above is inside a loop with a `continue` in it, so
        // a bundle that failed to load, or a day when every harness happened
        // to be quota-only, would leave this test green having checked
        // nothing.
        #expect(checked >= 10, "only \(checked) data-backed harnesses were checked")
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
            // A quota command runs on every refresh, so it belongs under the
            // same gate as the ones run during a scan.
            if let quota = descriptor.quota, let command = quota.command {
                commands.append("\(descriptor.id):quota \(([command] + (quota.args ?? [])).joined(separator: " "))")
            }
            // A focus command is run when a row is clicked, so it belongs
            // under the same gate as the ones run during a scan.
            if let focus = descriptor.focus {
                commands.append("\(descriptor.id):focus \(([focus.command] + (focus.args ?? [])).joined(separator: " "))")
            }
        }

        // Every command a shipped harness may run, listed here so adding one
        // is a decision rather than a side effect. All three read state and
        // write nothing: `gh auth token` prints a token, and the two workspace
        // managers print their live pane inventory as JSON.
        #expect(commands.sorted() == [
            "copilot:credential gh auth token",
            "herdr:focus herdr tab focus {focusTarget}",
            "herdr:source herdr api snapshot",
            "orca:focus orca terminal switch --terminal {focusTarget}",
            "orca:source orca terminal list --json",
        ])
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

/// Whether a benchmark run is one to gate on.
///
/// `verify.sh` printed three timings and checked none of them, so a scan that
/// became ten times slower appeared underneath "All checks passed". This app
/// was rebuilt because a scan was costing 54% of a core sustained; that shape
/// of failure is exactly what a guardrail is for.
@Suite("The scan budget")
struct ScanBudgetTests {

    @Test("A fast scan is within budget")
    func fastIsAcceptable() {
        #expect(HarnessPerformanceBudget.scanIsAcceptable(
            fastestMilliseconds: 350, backlogged: 0))
    }

    /// The boundary is inclusive: a run landing exactly on the budget has not
    /// exceeded it.
    @Test("A scan exactly at the budget passes, one past it does not")
    func boundaryIsInclusive() {
        let budget = HarnessPerformanceBudget.scanMilliseconds
        #expect(HarnessPerformanceBudget.scanIsAcceptable(
            fastestMilliseconds: budget, backlogged: 0))
        #expect(HarnessPerformanceBudget.scanIsAcceptable(
            fastestMilliseconds: budget + 1, backlogged: 0) == false)
    }

    /// A machine still absorbing transcript history is measuring catch-up
    /// throughput, which is legitimately slower and depends on whatever the
    /// developer has been running. Failing on that would fail for a reason
    /// nobody can act on.
    @Test("A backlogged run is not gated", arguments: [1, 5, 400])
    func backloggedIsNotGated(_ behind: Int) {
        #expect(HarnessPerformanceBudget.scanIsAcceptable(
            fastestMilliseconds: 60_000, backlogged: behind),
                "a catch-up run was failed for being slow")
    }

    /// A timing that is not a number is not a passing timing. There is no
    /// guard for this and no catalogue entry: NaN and infinity already
    /// compare false against the budget, so a guard would be a line nothing
    /// could catch. The behaviour is still worth pinning.
    @Test("A timing that is not a number fails", arguments: [
        Double.nan, .infinity,
    ])
    func nonFiniteFails(_ value: Double) {
        #expect(HarnessPerformanceBudget.scanIsAcceptable(
            fastestMilliseconds: value, backlogged: 0) == false)
    }

    /// The budget is about steady state, and the first pass is cold — it
    /// builds the caches the others read. Gating on the last pass instead
    /// would gate on whatever the machine was doing during it.
    @Test("The budget is measured against the fastest pass")
    func steadyStateIsTheFastest() {
        #expect(HarnessPerformanceBudget.steadyState([900, 340, 410]) == 340)
        #expect(HarnessPerformanceBudget.steadyState([340]) == 340)
    }

    /// The half of the gate that survives a backlog. A pass still absorbing
    /// history does the steady-state scan plus a read budget per transcript,
    /// so finishing under the budget anyway says something about steady
    /// state — and that is the case nearly every run is in.
    @Test("A backlogged run that comes in under budget is still a pass")
    func backloggedButFastIsGated() {
        #expect(HarnessPerformanceBudget.verdict(fastestMilliseconds: 340,
                                                 backlogged: 3) == .within)
    }

    /// And the half that does not. An over-budget run that was catching up
    /// may be perfectly fast once it has, so failing on it would fail for a
    /// reason nobody could act on.
    @Test("A backlogged run that is over budget concludes nothing")
    func backloggedAndSlowIsInconclusive() {
        #expect(HarnessPerformanceBudget.verdict(fastestMilliseconds: 99_000,
                                                 backlogged: 1) == .inconclusive)
    }

    @Test("A drained run that is over budget fails")
    func drainedAndSlowIsOver() {
        #expect(HarnessPerformanceBudget.verdict(fastestMilliseconds: 99_000,
                                                 backlogged: 0) == .over)
        #expect(HarnessPerformanceBudget.scanIsAcceptable(fastestMilliseconds: 99_000,
                                                          backlogged: 0) == false)
    }

    /// Draining before measuring is what makes the gate reachable. Without
    /// it, `scanIsAcceptable` waves through any machine carrying a backlog —
    /// which is most of them — so a scan ten times slower than its budget
    /// passed silently.
    @Test("A backlog is drained before the clock starts")
    func warmupDrainsBacklog() {
        #expect(HarnessPerformanceBudget.needsWarmup(backlogged: 3, passesRun: 0))
        #expect(HarnessPerformanceBudget.needsWarmup(backlogged: 1, passesRun: 4))
    }

    @Test("A run with nothing catching up spends no passes warming up")
    func noBacklogNoWarmup() {
        #expect(!HarnessPerformanceBudget.needsWarmup(backlogged: 0, passesRun: 0))
    }

    /// A transcript appended to as fast as it is read never drains. The bound
    /// is written out rather than derived from `maxWarmupPasses`, because a
    /// test that says "the limit is the limit" holds for every limit and so
    /// asserts nothing about this one.
    @Test("Warming up gives up after five passes rather than never finishing")
    func warmupIsBounded() {
        #expect(HarnessPerformanceBudget.maxWarmupPasses == 5)
        #expect(!HarnessPerformanceBudget.needsWarmup(backlogged: 99, passesRun: 5),
                "the drain loop would run for ever on a transcript being written to")
    }

    @Test("A run with no passes is not a fast run")
    func noPassesIsNotFast() {
        #expect(HarnessPerformanceBudget.scanIsAcceptable(
            fastestMilliseconds: HarnessPerformanceBudget.steadyState([]),
            backlogged: 0) == false)
    }

    /// Generous on purpose. A budget near what a healthy machine shows would
    /// fail on a busy laptop and be switched off, which is worse than a
    /// budget that only catches catastrophe.
    @Test("The budget is far above a healthy scan")
    func budgetIsGenerous() {
        #expect(HarnessPerformanceBudget.scanMilliseconds >= 5_000)
    }
}

/// The benchmark acts on its own verdict.
///
/// Checked in the source because `--bench` runs three full scans and exits,
/// which the suite does not do. The budget rule above says what acceptable
/// means; this says the command does something about it, which is the half
/// that was missing for the life of the step — verify.sh printed three
/// timings and checked none of them.
@Suite("The benchmark exits on its verdict")
struct BenchmarkVerdictContractTests {

    @Test("--bench exits non-zero when the scan is over budget")
    func benchExitsOnVerdict() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/Diagnostics.swift"), encoding: .utf8)
        let bench = try #require(text.range(of: #"contains("--bench")"#),
                                 "the benchmark command was renamed")
        // The block is long — three timed scans, a cache save and the
        // verdict — so the window has to reach past it. Measured rather than
        // guessed: 2,000 characters stopped short of the exit and the test
        // failed for the wrong reason.
        let body = String(text[bench.lowerBound...].prefix(4_000))
        #expect(body.contains("HarnessPerformanceBudget.verdict"),
                "the benchmark reaches no verdict")
        #expect(body.contains("exit(verdict == .over ? 1 : 0)"),
                "the benchmark reaches a verdict and exits zero regardless")
        #expect(body.contains("HarnessPerformanceBudget.needsWarmup"),
                "the benchmark measures before absorbing its backlog")
        #expect(body.contains("HarnessPerformanceBudget.steadyState"),
                "the benchmark picks its own pass to judge")
    }

    /// And verify.sh acts on the exit status rather than only printing it,
    /// which is what it did before.
    @Test("verify.sh checks the benchmark's status")
    func verifyChecksTheStatus() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("verify.sh"),
                              encoding: .utf8)
        #expect(text.contains("scan is over its budget"),
                "the benchmark step reports timings and gates on nothing")
    }
}

/// The cost of sitting there, which is a different question from the cost of
/// one scan.
///
/// The failure this project was rebuilt around was not a slow scan but a
/// frequent one: 408 minutes of CPU over fifteen hours, which is 44% of a
/// core sustained, from a loop running far more often than it should. The
/// scan benchmark times a single pass and cannot see that. A verify step
/// measures what the app costs while idle, and this holds that the step
/// reaches a verdict rather than printing a number.
@Suite("Idle cost is measured and gated")
struct IdleCostContractTests {

    private func verifyScript() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("verify.sh"),
                          encoding: .utf8)
    }

    @Test("verify.sh measures sustained cost and fails on it")
    func idleCostIsGated() throws {
        let text = try verifyScript()
        #expect(text.contains("Sustained cost while idle"),
                "nothing measures what the app costs while it sits there")
        #expect(text.contains("the shape of a runaway loop"),
                "the idle measurement reports a number and gates on nothing")
        #expect(text.contains("resident size"),
                "nothing watches memory, which was the other half of the failure")
    }

    /// The first thirty seconds are cold caches and first-run detection,
    /// which are legitimately busy. Measuring them would set a budget around
    /// startup rather than around steady state.
    @Test("The measurement is of the second half, not the first")
    func measuresSteadyState() throws {
        let text = try verifyScript()
        #expect(text.contains("second thirty"),
                "the idle budget includes startup, which is not steady state")
    }
}

/// Every shipped harness is verified offline by one mechanism or the other.
///
/// Two suites cover the two kinds: a data-backed harness must have a passing
/// dated session fixture, and one declaring a quota must have a passing
/// quota fixture. Between them they check all twenty-five — but they
/// partition by `source.kind`, and nothing said the partition was
/// exhaustive. A descriptor with no session source and no quota block sits
/// in neither: it decodes, it ships, and no fixture anywhere replays it.
///
/// There is a third kind the two suites do not see, and finding it was the
/// point: a descriptor that exists for presence alone — a name, a mark, a
/// process rule — whose figures come from a provider written in Swift.
/// Claude and Gemini are both, because a keychain and an OAuth refresh are
/// not things a descriptor can describe. They are covered, by mapping tests
/// and by mutations, and this asks for the provider rather than a fixture.
///
/// This is the promise that the whole catalogue can be checked without
/// installing a single one of these agents, stated as one property rather
/// than inferred from two and a gap.
@Suite("No shipped harness escapes both fixtures")
struct EveryHarnessIsVerifiedOfflineTests {

    @Test("Each one is covered by a session fixture or a quota fixture")
    func everyHarnessHasEvidence() throws {
        let descriptors = HarnessCLI.bundledDescriptors()
        #expect(descriptors.count >= 20, "only \(descriptors.count) harnesses were read")

        var session = 0, quota = 0, uncovered: [String] = [], native: [String] = []
        for descriptor in descriptors {
            let hasSession = descriptor.source.kind != .none
            let hasQuota = descriptor.quota != nil
            switch (hasSession, hasQuota) {
            case (true, _):
                // Checked by the session fixture suite above.
                session += 1
                #expect(descriptor.compatibility?.fixture?.isEmpty == false,
                        Comment(rawValue: "\(descriptor.id) reads sessions and declares no fixture"))
            case (false, true):
                // Checked by the quota fixture suite.
                quota += 1
                let report = QuotaFixture.verify(descriptor, in: AppResources.bundle)
                #expect(report?.passed == true,
                        Comment(rawValue: "\(descriptor.id): \(report?.detail ?? "no report")"))
            case (false, false):
                // The third kind, and the one the two suites do not see: a
                // descriptor that exists for presence — a name, a mark, a
                // process rule — whose figures come from a provider written
                // in Swift. Claude and Gemini are both of these, because
                // their credentials are a keychain and an OAuth refresh.
                // Covered, but by mapping tests and mutations rather than by
                // a fixture, so that is what is asked of them here.
                native.append(descriptor.id)
                #expect(ProviderRegistry.all.contains { $0.id == descriptor.id },
                        Comment(rawValue: "\(descriptor.id) reads nothing, reports nothing "
                                + "and has no provider behind it, so nothing verifies it"))
            }
        }
        #expect(uncovered.isEmpty,
                Comment(rawValue: "these read nothing and report nothing, so no fixture "
                        + "replays them: \(uncovered.joined(separator: ", "))"))
        // Each kind must be non-empty, or this passes by everything
        // happening to be one of them.
        #expect(session >= 10, "only \(session) harnesses read sessions")
        #expect(quota >= 5, "only \(quota) harnesses declare a quota")
        #expect(!native.isEmpty, "no presence-only harness was seen")
        #expect(session + quota + native.count == descriptors.count)
    }
}
