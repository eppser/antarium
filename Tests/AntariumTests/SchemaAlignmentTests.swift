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
