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

    /// Properties of one definition, following a `$ref` to another.
    private func properties(of name: String, in defs: [String: Any]) -> Set<String>? {
        guard var node = defs[name] as? [String: Any] else { return nil }
        if let ref = node["$ref"] as? String,
           let target = ref.split(separator: "/").last.map(String.init),
           let resolved = defs[target] as? [String: Any] { node = resolved }
        guard let props = node["properties"] as? [String: Any] else { return nil }
        return Set(props.keys)
    }

    @Test("There are definitions and key lists to compare")
    func thereIsSomethingToCompare() throws {
        let defs = try definitions(try schema())
        #expect(defs.count >= 10, Comment(rawValue: "only \(defs.count) definitions"))
        #expect(HarnessCheck.known.count >= 15,
                Comment(rawValue: "only \(HarnessCheck.known.count) key lists"))
    }

    /// For every section the schema defines under its own name, the two
    /// lists agree exactly. A key in one and not the other is either a field
    /// the validator will reject and the loader accepts, or one the schema
    /// forbids and the validator waves through.
    @Test("Each section the schema names holds the keys the validator expects")
    func listsAgreeWithTheSchema() throws {
        let defs = try definitions(try schema())
        var compared = 0
        for (section, keys) in HarnessCheck.known {
            // The validator names nested sections with dots; the schema names
            // each definition once. Compare the leaf.
            let name = section.split(separator: ".").last.map(String.init) ?? section
            guard !name.isEmpty, let declared = properties(of: name, in: defs) else { continue }
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
        #expect(compared >= 8,
                Comment(rawValue: "only \(compared) sections could be compared, so this "
                        + "proved little"))
    }

    /// The specific pair that drifted, named so it cannot quietly stop being
    /// compared if the section is renamed.
    @Test("A manifest's map is the session map, in both lists")
    func manifestMapIsTheMap() throws {
        let defs = try definitions(try schema())
        #expect(HarnessCheck.known["source.manifest.map"] == HarnessCheck.known["map"],
                "a manifest's map and the session map are different lists again")
        #expect(HarnessCheck.known["map"]?.contains("focusTarget") == true)
        #expect(properties(of: "map", in: defs)?.contains("focusTarget") == true,
                "the schema no longer allows a focus target in a map")
    }
}
