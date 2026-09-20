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
