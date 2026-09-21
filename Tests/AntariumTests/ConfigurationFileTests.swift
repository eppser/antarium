import Foundation
import Darwin
import Testing
@testable import Antarium

@Suite("Settings persistence boundaries")
struct ConfigurationFileTests {
    private func fixture(_ body: (URL, ConfigurationFile) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        try body(url, ConfigurationFile(url: url))
    }

    @Test("Malformed external edits preserve the last good settings and cannot be overwritten")
    func malformed() throws {
        try fixture { url, file in
            try Data(#"{"palette":"ember"}"#.utf8).write(to: url)
            #expect(file.string("palette") == "ember")
            let invalid = Data(#"{"palette": "unfinished"#.utf8)
            try invalid.write(to: url)
            file.reload()
            #expect(file.string("palette") == "ember")
            file.set("refreshMinutes", 3)
            #expect(try Data(contentsOf: url) == invalid)
        }
    }

    @Test("Settings numbers and booleans are not interchangeable")
    func numericTypes() throws {
        try fixture { url, file in
            try Data(#"{"bool":true,"one":1,"fraction":1.5,"zero":0,"list":[1,true,2]}"#.utf8).write(to:url)
            #expect(file.int("bool") == nil)
            #expect(file.double("bool") == nil)
            #expect(file.bool("one") == nil)
            #expect(file.int("fraction") == nil)
            #expect(file.int("zero") == 0)
            #expect(file.doubles("list") == nil)
        }
    }

    @Test("Concurrent independent edits do not lose settings")
    func concurrentUpdates() throws {
        try fixture { url, file in
            DispatchQueue.concurrentPerform(iterations: 64) { index in file.set("fixture-\(index)", index) }
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:url)) as? [String:Any])
            #expect(saved.count == 64)
        }
    }

    @Test("New settings files have private permissions")
    func permissions() throws {
        try fixture { url, file in
            file.set("palette", "ember")
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o600)
        }
    }

    @Test("Oversized, linked and nonregular files cannot be read or replaced")
    func unsafeFiles() throws {
        try fixture { url, file in
            let oversized = Data(repeating: 32, count: ConfigurationFile.maximumBytes + 1)
            try oversized.write(to: url)
            #expect(!file.set("new", "value"))
            #expect(file.issue != nil)
            #expect(try Data(contentsOf: url) == oversized)
            try FileManager.default.removeItem(at: url)
            let target = url.deletingLastPathComponent().appendingPathComponent("target.json")
            let original = Data(#"{"private":"synthetic-only"}"#.utf8)
            try original.write(to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            #expect(!file.set("new", "value"))
            #expect(try Data(contentsOf: target) == original)
            try FileManager.default.removeItem(at: url)
            #expect(mkfifo(url.path, 0o600) == 0)
            let began = ProcessInfo.processInfo.systemUptime
            #expect(!file.set("new", "value"))
            #expect(ProcessInfo.processInfo.systemUptime - began < 1)
        }
    }

    @Test("Bad values and excessive saves preserve the existing file")
    func badSaves() throws {
        try fixture { url, file in
            #expect(file.set("good", "value"))
            let original = try Data(contentsOf: url)
            #expect(!file.set("bad", Double.nan))
            #expect(!file.set("large", String(repeating: "x", count: ConfigurationFile.maximumBytes)))
            #expect(try Data(contentsOf: url) == original)
            #expect(file.string("good") == "value")
            #expect(file.issue != nil)
            file.reload()
            #expect(file.issue == nil)
        }
    }

    @Test("Extreme numbers remain bounded and integer precision is preserved")
    func extremeNumbers() throws {
        try fixture { url, file in
            try Data(#"{"huge":1e300,"max":9223372036854775807,"min":-9223372036854775808}"#.utf8).write(to:url)
            #expect(file.int("huge") == nil)
            #expect(file.int("max") == Int.max)
            #expect(file.int("min") == Int.min)
        }
    }

    @Test("Migration preserves external settings and malformed files")
    func migration() throws {
        try fixture { url, file in
            file.migrateIfEmpty(["palette":"ember"])
            #expect(file.string("palette") == "ember")
            file.migrateIfEmpty(["palette":"ocean"])
            #expect(file.string("palette") == "ember")
            let invalid = Data("malformed".utf8)
            try invalid.write(to: url)
            file.migrateIfEmpty(["palette":"ocean"])
            #expect(try Data(contentsOf:url) == invalid)
        }
    }
}

/// What the app does before anyone has told it anything. A default is a
/// decision made on the user's behalf, and the ones that reach outward —
/// connecting to other machines, making noise, showing alerts — are the ones
/// worth stating, because getting one wrong means a fresh install doing
/// something nobody asked for.
///
/// Read from the source rather than at runtime. `Config` binds to the real
/// settings directory the first time it is touched, so a test that reads
/// these accessors reports this machine's choices — the first version of this
/// suite asserted `notifyOnIdle` was off and failed, because on this Mac it
/// is on. That is the developer's preference, not the default.
@Suite("Outward-facing settings are off until asked for")
struct SettingsDefaultTests {

    private var settingsSource: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(
                "Sources/Antarium/UI/Settings.swift"), encoding: .utf8)
        }
    }

    /// Reaching out to other machines over SSH, and showing alerts, are
    /// opt-in. A `?? true` on either means a fresh install starts doing it.
    @Test("Settings that reach outward default to off", arguments: [
        "includeRemoteTmux", "notifyOnIdle",
    ])
    func outwardSettingsAreOptIn(_ key: String) throws {
        let source = try settingsSource
        let line = source.split(separator: "\n")
            .first { $0.contains("Config.bool(\"\(key)\")") }
        let found = try #require(line.map(String.init), "\(key) has no accessor")
        #expect(found.contains("?? false"),
                Comment(rawValue: "\(key) defaults to on: \(found.trimmingCharacters(in: .whitespaces))"))
    }

    /// Sounds are opt-in for the same reason, and there are several of them —
    /// a new event added later must not arrive switched on.
    @Test("Every sound is off until switched on")
    func soundsAreOptIn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/UI/Sounds.swift"), encoding: .utf8)
        let line = source.split(separator: "\n").first { $0.contains("func isEnabled") }
        let found = try #require(line.map(String.init))
        #expect(found.contains("?? false"),
                Comment(rawValue: "sounds default to on: \(found.trimmingCharacters(in: .whitespaces))"))
        #expect(Sounds.Event.allCases.count >= 2, "no sound events, so this proved nothing")
    }

    /// Reading cloud tasks costs a request the app was going to make anyway,
    /// so it is on — stated here so the asymmetry with the others is a
    /// decision rather than an oversight.
    @Test("Cloud tasks are on, deliberately")
    func cloudIsOnByDefault() throws {
        let source = try settingsSource
        let line = source.split(separator: "\n")
            .first { $0.contains("Config.bool(\"includeCloudAgents\")") }
        #expect(try #require(line.map(String.init)).contains("?? true"))
    }

    /// An interval read from a file the user can edit by hand. Without the
    /// clamp a zero there is a scan loop with no gap in it.
    @Test("The scan interval is clamped in both directions")
    func scanIntervalIsClamped() throws {
        let source = try settingsSource
        let line = source.split(separator: "\n")
            .first { $0.contains("Config.int(\"agentScanSeconds\")") }
        let found = try #require(line.map(String.init))
        #expect(found.contains("min(") && found.contains("max("),
                Comment(rawValue: "the scan interval is unclamped: \(found)"))
    }
}
