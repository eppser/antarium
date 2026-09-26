import Foundation
import Testing
@testable import Antarium

/// The validator's key lists and the JSON schema describe the same fields.
///
/// A descriptor's shape is written down three times: in the SDK's types,
/// in `harness.schema.json`, and in `HarnessCheck.known` — the list `--check`
/// uses to tell an author that a key is a typo. Nothing connected them.
///
/// The drift that prompted this: a manifest carries a map of the same type as
/// the session map, the schema says so with a `$ref`, and the decoder agrees
/// because `Manifest.map` is of type `Map`. The validator's copy of that list
/// was written out by hand and had lost `focusTarget`. A descriptor the
/// schema accepts and the decoder reads was reported as carrying a field that
/// "is not a field; it will be ignored", of a field that is read.
@Suite("The validator and the schema describe the same descriptor")
struct SchemaAlignmentTests {

    private func schema() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/harness.schema.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any], "the schema is not an object")
    }

    private func definitions(_ schema: [String: Any]) throws -> [String: Any] {
        try #require(schema["$defs"] as? [String: Any], "the schema declares no definitions")
    }

    /// Follows a `$ref` until it reaches a real node.
    private func deref(_ node: Any?, _ defs: [String: Any]) -> [String: Any]? {
        var current = node as? [String: Any]
        for _ in 0..<10 {
            guard let ref = current?["$ref"] as? String,
                  let name = ref.split(separator: "/").last.map(String.init) else { break }
            current = defs[name] as? [String: Any]
        }
        return current
    }

    /// The fields the schema allows at one of the validator's paths, walked
    /// from the root rather than looked up by its last component.
    ///
    /// By leaf name, eight of the nineteen sections did not resolve — they
    /// are nested objects, not definitions of their own — and a section that
    /// does not resolve is a section not compared. That is how the drift got
    /// in: the check before this one took its subjects from a list somebody
    /// maintained by hand, and its completeness guard counted the entries
    /// rather than asking whether any were missing.
    private func schemaFields(at path: String, _ schema: [String: Any],
                              _ defs: [String: Any]) -> Set<String>? {
        var node = deref(schema, defs)
        if !path.isEmpty {
            for part in path.split(separator: ".") {
                guard let properties = node?["properties"] as? [String: Any],
                      var next = deref(properties[String(part)], defs) else { return nil }
                if next["properties"] == nil, let items = deref(next["items"], defs) {
                    next = items
                }
                node = next
            }
        }
        guard let properties = node?["properties"] as? [String: Any] else { return nil }
        return Set(properties.keys)
    }

    /// A date field the schema will not constrain is a date field nobody
    /// outside this repository is told the shape of.
    ///
    /// Nothing here runs a JSON-schema validator — the schema is what someone
    /// writing their own harness reads, and the app checks descriptors its
    /// own way. So the constraint has to be asserted as text, the way this
    /// file already compares the validator's key lists with the schema's.
    /// Without it `quota.checkedAt` could lose its pattern and every shipped
    /// descriptor would still pass, while an author following the schema
    /// learned nothing about what a date looks like here.
    @Test("The date a mapping was last read is constrained to a date")
    func checkedAtIsConstrained() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: "Resources/harness.schema.json"),
                              encoding: .utf8)
        let block = try #require(text.range(of: "\"checkedAt\""),
                                 "the schema no longer describes quota.checkedAt")
        let after = text[block.upperBound...].prefix(400)
        #expect(after.contains("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"),
                "quota.checkedAt accepts any string, so the schema states no shape for a date")
    }

    /// Every section the validator knows about is compared. Not a count of
    /// them — a count is satisfied by a list that is long enough and still
    /// missing the one that matters.
    @Test("Every section the validator knows is described by the schema")
    func everySectionResolves() throws {
        let schema = try schema()
        let defs = try definitions(schema)
        var unresolved: [String] = []
        for section in HarnessCheck.known.keys.sorted()
        where schemaFields(at: section, schema, defs) == nil {
            unresolved.append(section)
        }
        #expect(unresolved.isEmpty,
                Comment(rawValue: "the schema describes no such section, so --check is the "
                        + "only thing that has an opinion about it: "
                        + unresolved.joined(separator: ", ")))
    }

    /// For every section, in both directions. A key in one and not the other
    /// is either a field the validator will reject and the loader accepts, or
    /// one the schema forbids and the validator waves through.
    @Test("Each section holds the keys the validator expects")
    func listsAgreeWithTheSchema() throws {
        let schema = try schema()
        let defs = try definitions(schema)
        var compared = 0
        for (section, keys) in HarnessCheck.known {
            guard let declared = schemaFields(at: section, schema, defs) else { continue }
            compared += 1
            let validatorOnly = keys.subtracting(declared).sorted()
            let schemaOnly = declared.subtracting(keys).sorted()
            #expect(validatorOnly.isEmpty,
                    Comment(rawValue: "\(section): the validator knows "
                            + "\(validatorOnly.joined(separator: ", ")) and the schema does not"))
            #expect(schemaOnly.isEmpty,
                    Comment(rawValue: "\(section): the schema allows "
                            + "\(schemaOnly.joined(separator: ", ")) and the validator calls it "
                            + "a typo"))
        }
        #expect(compared == HarnessCheck.known.count,
                Comment(rawValue: "\(compared) of \(HarnessCheck.known.count) sections were "
                        + "compared"))
    }

    /// The specific pair that drifted, named so it cannot quietly stop being
    /// compared if the section is renamed.
    @Test("A manifest's map is the session map, in both lists")
    func manifestMapIsTheMap() throws {
        let schema = try schema()
        let defs = try definitions(schema)
        #expect(HarnessCheck.known["source.manifest.map"] == HarnessCheck.known["map"],
                "a manifest's map and the session map are different lists again")
        #expect(HarnessCheck.known["map"]?.contains("focusTarget") == true)
        #expect(schemaFields(at: "source.manifest.map", schema, defs)?.contains("focusTarget")
                == true,
                "the schema no longer allows a focus target in a manifest's map")
    }
}

/// The suite notices when a test file stops containing tests.
///
/// Written because it happened. A script rewrote a test file, `open(path,
/// "w")` truncated it, the write raised before producing anything, and the
/// file was left at zero bytes. An empty Swift file compiles, so the suite
/// ran green with seven tests gone — 1,566 became 1,559 and nothing said so.
/// The count is printed on every run and is exactly the kind of number a
/// person reads as "still passing".
///
/// This is the same rule the rest of the repository already applies to
/// fixtures and descriptors — coverage is asserted as set equality in both
/// directions, so a thing that quietly disappears fails rather than shrinks
/// the total. The test files themselves were the one collection nothing
/// counted.
@Suite("Every test file still contains tests")
struct TestFilePresenceTests {

    /// Files that legitimately declare no test: shared helpers and the
    /// isolation hook. Named individually, so a third one has to be admitted
    /// deliberately rather than by matching a pattern.
    static let helpers: Set<String> = ["SourceText.swift", "HarnessEngineTestIsolation.swift"]

    private var files: [URL] {
        get throws {
            let dir = URL(fileURLWithPath: "Tests/AntariumTests")
            return try FileManager.default
                .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    @Test("There are test files to check, and this is reading the right folder")
    func theFolderIsFound() throws {
        let found = try files
        #expect(found.count >= 80,
                Comment(rawValue: "only \(found.count) test files were found"))
    }

    @Test("No test file is empty")
    func noneIsEmpty() throws {
        for file in try files {
            let size = try Data(contentsOf: file).count
            #expect(size > 0,
                    Comment(rawValue: "\(file.lastPathComponent) is empty"))
        }
    }

    @Test("Every test file declares a test, or is a named helper")
    func everyFileDeclaresTests() throws {
        for file in try files {
            let name = file.lastPathComponent
            guard !Self.helpers.contains(name) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("@Test"),
                    Comment(rawValue: "\(name) declares no test and is not a named helper — "
                            + "if it lost its contents the suite would still pass"))
        }
    }

    /// And the helper list does not quietly grow to cover a file that lost
    /// its tests: each named helper must still exist and still declare none.
    @Test("Each named helper is real and still a helper")
    func helpersAreHelpers() throws {
        let present = Set(try files.map(\.lastPathComponent))
        for helper in Self.helpers {
            #expect(present.contains(helper),
                    Comment(rawValue: "\(helper) is listed as a helper and does not exist"))
            let text = try String(contentsOf: URL(fileURLWithPath: "Tests/AntariumTests/\(helper)"),
                                  encoding: .utf8)
            #expect(!text.contains("@Test"),
                    Comment(rawValue: "\(helper) declares tests and should not be exempt"))
        }
    }
}
