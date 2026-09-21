import Foundation
import Testing
@testable import Antarium

/// AGENTS.md requires a descriptor change to land across the SDK, schema,
/// decoder, migration, documentation, fixtures and tests together. Every part
/// of that is enforced by something except the documentation, which is the
/// part a reader relies on and the easiest to forget. This closes it.
@Suite("Documentation tracks the schema")
struct DocumentationAlignmentTests {

    /// The repository, found from this file rather than the working directory,
    /// which differs between `swift test` and the script runner.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)            // Tests/AntariumTests/<this>
            .deletingLastPathComponent()           // Tests/AntariumTests
            .deletingLastPathComponent()           // Tests
            .deletingLastPathComponent()           // repository root
    }

    private func schemaFields(_ definition: String) throws -> [String] {
        let url = repositoryRoot.appendingPathComponent("Resources/harness.schema.json")
        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defs = try #require(object["$defs"] as? [String: Any])
        let block = try #require(defs[definition] as? [String: Any])
        let properties = try #require(block["properties"] as? [String: Any])
        return properties.keys.sorted()
    }

    @Test("Every quota window field the schema accepts is explained in the docs")
    func quotaWindowFieldsAreDocumented() throws {
        let documentation = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/TECHNICAL.md"),
            encoding: .utf8)
        let undocumented = try schemaFields("windows").filter {
            !documentation.contains("`\($0)`")
        }
        let missing = undocumented.joined(separator: ", ")
        #expect(undocumented.isEmpty,
                "quota.windows fields with no explanation in docs/TECHNICAL.md: \(missing)")
    }

    @Test("The validator, the schema and the SDK accept the same window fields")
    func schemaAndValidatorAgree() throws {
        // A field the schema allows but the validator rejects is reported to
        // the user as a typo in their own file; the reverse is silently
        // ignored. Both are worse than a build failure here.
        let schema = Set(try schemaFields("windows"))
        let validator = Set(HarnessCheck.knownFields(at: "quota.windows") ?? [])
        let schemaOnly = schema.subtracting(validator).sorted()
        let validatorOnly = validator.subtracting(schema).sorted()
        #expect(schema == validator,
                "schema only: \(schemaOnly); validator only: \(validatorOnly)")
    }

    @Test("Every quota credential kind the schema names is one the provider reads")
    func credentialKindsAgree() throws {
        let url = repositoryRoot.appendingPathComponent("Resources/harness.schema.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let defs = try #require(object?["$defs"] as? [String: Any])
        let credential = try #require(defs["credential"] as? [String: Any])
        let properties = try #require(credential["properties"] as? [String: Any])
        let kind = try #require(properties["kind"] as? [String: Any])
        let kinds = Set(try #require(kind["enum"] as? [String]))
        #expect(kinds == ["env", "textFile", "jsonFile", "command"])
    }
}

/// The validator's idea of what a descriptor may contain, against the
/// schema's.
///
/// `--check` reports any key it does not know as "not a field; it will be
/// ignored". When a field is added to the runtime and the schema but not to
/// that list, the tool tells the one person writing such a descriptor that
/// their working field does nothing — which is worse than silence, and is
/// what happened to `quota.command`, `args`, `method` and `body`.
@Suite("The validator and the schema describe the same descriptor")
struct ValidatorSchemaAlignmentTests {

    /// Each validator key path against the schema definition that describes
    /// the same object. Paths the schema models inline, or not at all, are
    /// left out rather than asserted loosely.
    private static let pairs: [(path: String, definition: String)] = [
        ("quota", "quota"),
        ("quota.windows", "windows"),
        ("quota.credential", "credential"),
        ("source", "source"),
        ("map", "map"),
        ("process", "process"),
        ("selection", "selection"),
        ("focus", "focus"),
        ("presentation", "presentation"),
        ("compatibility", "compatibility"),
    ]

    /// A parameterised test over an empty list passes. Both tests below take
    /// their arguments from `pairs`, so emptying it would turn the whole
    /// alignment check into two green ticks — which is the failure this
    /// suite exists to prevent, one level out.
    @Test("Every object with a key list is compared")
    func everyObjectIsCompared() {
        #expect(Self.pairs.count >= 10,
                "only \(Self.pairs.count) objects are compared")
        #expect(Set(Self.pairs.map(\.path)).count == Self.pairs.count,
                "an object is listed twice, so one of them is not being checked")
    }

    private func schemaProperties(_ definition: String) throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/harness.schema.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defs = try #require(json["$defs"] as? [String: Any])
        let object = try #require(defs[definition] as? [String: Any],
                                  "the schema has no definition named \(definition)")
        let properties = try #require(object["properties"] as? [String: Any])
        return Set(properties.keys)
    }

    @Test("Every schema field is one the validator knows",
          arguments: ValidatorSchemaAlignmentTests.pairs)
    func schemaFieldsAreKnown(_ pair: (path: String, definition: String)) throws {
        let known = try #require(HarnessCheck.known[pair.path],
                                 "the validator has no key list for \(pair.path)")
        let missing = try schemaProperties(pair.definition).subtracting(known)
        #expect(missing.isEmpty, Comment(rawValue:
            "\(pair.path) accepts \(missing.sorted()) in the schema, and --check would "
            + "call each of them \"not a field; it will be ignored\""))
    }

    /// And the other direction, so the validator cannot quietly accept a key
    /// nothing else describes.
    @Test("Every field the validator knows is in the schema",
          arguments: ValidatorSchemaAlignmentTests.pairs)
    func knownFieldsAreInTheSchema(_ pair: (path: String, definition: String)) throws {
        let known = try #require(HarnessCheck.known[pair.path])
        let extra = known.subtracting(try schemaProperties(pair.definition))
        #expect(extra.isEmpty, Comment(rawValue:
            "\(pair.path) accepts \(extra.sorted()) and the schema does not describe them"))
    }
}

/// Two documented claims that changed under the documentation.
///
/// The quota section said a descriptor "makes one authenticated GET" and that
/// an endpoint "must be https with a host". Both were true when written and
/// neither survived this month — a POST is describable now, and http to this
/// machine is accepted. The new paragraphs were appended a hundred lines
/// further down, so the file said both things at once.
@Suite("The quota documentation says what the code does")
struct QuotaDocumentationTests {

    private func technical() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("docs/TECHNICAL.md"),
                          encoding: .utf8)
    }

    /// Stated as an absence, because the failure was a stale sentence left
    /// standing beside a new one rather than a missing explanation.
    @Test("Nothing claims a quota endpoint must be https")
    func noHttpsOnlyClaim() throws {
        let text = try technical()
        #expect(!text.contains("must be `https` with a host"),
                "the scheme rule changed and this sentence did not")
        #expect(text.contains("https, or http to this machine"),
                "the scheme rule is not stated anywhere")
    }

    @Test("Nothing claims a quota is always a GET")
    func noGetOnlyClaim() throws {
        let text = try technical()
        #expect(!text.contains("makes one authenticated GET"),
                "a POST is describable and this sentence says otherwise")
        #expect(text.contains(#"`method: "POST"`"#),
                "the posted form is not documented")
    }

    /// And the command form, which is the third transport and the newest.
    @Test("The command form is documented")
    func commandFormDocumented() throws {
        #expect(try technical().contains("`quota.command`")
                || (try technical()).contains("an `endpoint`, or a `command`"))
    }

    /// The walkthrough exists and names the two commands that make a mapping
    /// checkable with nothing installed, which is the whole point of it.
    ///
    /// Scoped to the section rather than the file. Both commands appear
    /// elsewhere in this document, so a whole-file `contains` passed with the
    /// step deleted — the same mistake as matching a path as a substring, and
    /// the mutation that removed the step survived it.
    @Test("Adding a provider is written down, with the commands that verify it")
    func walkthroughExists() throws {
        let text = try technical()
        let start = try #require(text.range(of: "### Adding a quota provider"),
                                 "the walkthrough is gone")
        let after = text[start.upperBound...]
        let end = after.range(of: "\n### ")?.lowerBound ?? after.endIndex
        let section = String(after[..<end])

        #expect(section.contains("--check"),
                "the walkthrough does not say how to check the descriptor")
        #expect(section.contains("--verify-harness-quota"),
                "the walkthrough does not say how to check the mapping")
        #expect(section.contains("mutations.txt"),
                "the walkthrough stops at a fixture, which only proves today")
        #expect(section.contains("ECOSYSTEM"),
                "the walkthrough does not say where a guessed mapping ends up")
        #expect(section.count > 400, "the walkthrough is \(section.count) characters")
    }
}
