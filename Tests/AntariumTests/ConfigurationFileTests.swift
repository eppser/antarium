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

/// What happens when the settings file cannot be read.
///
/// Writes refuse to destroy a file they cannot parse, which is right — it may
/// be somebody's settings with a typo in them. The consequence is that
/// nothing can be saved until it is fixed, and that consequence has to be
/// said out loud somewhere.
@Suite("An unreadable settings file", .serialized)
struct UnreadableConfigurationTests {

    private func file(_ contents: String) throws -> (ConfigurationFile, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-\(UUID()).json")
        try Data(contents.utf8).write(to: url)
        return (ConfigurationFile(url: url), url)
    }

    @Test("A file that is not JSON reports why")
    func brokenFileReportsWhy() throws {
        let (config, url) = try file("{ not json")
        defer { try? FileManager.default.removeItem(at: url) }
        let issue = try #require(config.issue, "an unreadable file reported nothing")
        #expect(issue.contains("could not be read"))
    }

    /// The refusal itself. Overwriting would discard settings nobody has
    /// agreed to lose.
    @Test("A write is refused rather than destroying the file")
    func writeIsRefused() throws {
        let (config, url) = try file("{ not json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(config.set("a", 1) == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json",
                "an unreadable settings file was overwritten")
    }

    /// And once it is valid again, saving resumes — the refusal is about the
    /// file's state, not a latch that stays set.
    @Test("Repairing the file restores saving")
    func repairRestoresSaving() throws {
        let (config, url) = try file("{ not json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(config.set("a", 1) == false)

        try Data("{}".utf8).write(to: url)
        config.reload()
        #expect(config.issue == nil, "a repaired file still reported a problem")
        #expect(config.set("a", 1), "a repaired file still refused to save")
        #expect(config.int("a") == 1)
    }

    @Test("An ordinary file reports no problem and saves")
    func ordinaryFileWorks() throws {
        let (config, url) = try file(#"{"a":1}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(config.issue == nil)
        #expect(config.set("b", 2))
        #expect(config.int("b") == 2)
    }
}

/// The two places that report a damaged settings file without being runnable
/// from a test: a launch, which builds menu bar items and a run loop, and
/// `verify.sh`, which is a shell script.
@Suite("A damaged settings file is reported where it is noticed")
struct DamagedConfigurationReportingContractTests {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("A launch logs it, before it seeds anything")
    func launchLogsIt() throws {
        let text = try source("Sources/Antarium/AppController.swift")
        let start = try #require(text.range(of: "func start() {"))
        let body = String(text[start.lowerBound...].prefix(900))
        let logged = try #require(body.range(of: "Log.warn(\"config\", issue)"),
                                  "a launch says nothing about an unreadable settings file")
        let seed = try #require(body.range(of: "HarnessDescriptor.seed()"))
        #expect(logged.lowerBound < seed.lowerBound,
                "it is mentioned after the work that depends on settings")
    }

    @Test("verify.sh checks that a damaged machine still starts")
    func verifyChecksDamage() throws {
        let text = try source("verify.sh")
        #expect(text.contains("A machine whose files have been damaged"))
        #expect(text.contains("a damaged file stopped it starting"),
                "the damaged-machine step reports and gates on nothing")
        #expect(text.contains("a bad descriptor cost more than itself"),
                "nothing checks that one bad descriptor costs one harness")
    }
}

/// A save that cannot be written, which is a different failure from a file
/// that cannot be read.
///
/// A full disk, a directory somebody has made read-only, a volume unmounted
/// mid-session. The existing file is preserved either way — writes go to a
/// temporary file and are renamed over — and the message says which of the
/// two happened, because "fix your settings file" is wrong advice when the
/// settings file is fine and the disk is full.
@Suite("A settings file that cannot be written", .serialized)
struct UnwritableConfigurationTests {

    @Test("A save into a directory that cannot be written is refused and reported")
    func unwritableDirectoryIsReported() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unwritable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                    ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"a":1}"#.utf8).write(to: url)

        let config = ConfigurationFile(url: url)
        #expect(config.int("a") == 1, "the file did not read back before being locked")
        #expect(config.issue == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)
        let saved = config.set("b", 2)
        // Root ignores the permission bits, so this only asserts where the
        // directory actually became unwritable.
        guard !saved || getuid() == 0 else {
            Issue.record("the directory did not become unwritable; nothing was tested")
            return
        }
        guard !saved else { return }

        let issue = try #require(config.issue, "a failed save reported nothing")
        #expect(issue.contains("not saved"),
                "the message does not say the save failed: \(issue)")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"a\""),
                "a failed save damaged the file it could not replace")
    }

    /// And the two messages are different, because the remedies are: one asks
    /// you to fix the file, the other tells you the file is fine.
    @Test("An unreadable file and an unwritable one do not say the same thing")
    func theTwoFailuresReadDifferently() throws {
        let broken = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-\(UUID()).json")
        try Data("{ not json".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        let readFailure = try #require(ConfigurationFile(url: broken).issue)
        #expect(readFailure.contains("could not be read"))
        #expect(!readFailure.contains("not saved"),
                "a file that cannot be read reports a save that never happened")
    }
}
