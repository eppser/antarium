import Foundation
import Testing
@testable import AntariumHarnessSDK

/// Migration rewrites harness files people already have. Anything it drops is
/// a setting that silently stops applying, on a file the user may have
/// written themselves.
@Suite("Migrating an older harness keeps what it says")
struct SDKMigrationTests {

    private func migrate(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        let result = try HarnessConfigMigration.migrate(data, prettyPrinted: false)
        return try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
    }

    private var v0: [String: Any] {
        ["id": "synthetic", "name": "Synthetic",
         "match": ["/synthetic/versions/"],
         "matchProcessName": ["synthetic"],
         "mark": "synthetic-glyph",
         "fallbackName": "Synthetic Agent",
         "source": ["kind": "none", "path": ""]]
    }

    @Test("The old top-level keys move into the process block")
    func processKeysMove() throws {
        let out = try migrate(v0)
        let process = try #require(out["process"] as? [String: Any])
        #expect(process["pathContains"] as? [String] == ["/synthetic/versions/"])
        #expect(process["names"] as? [String] == ["synthetic"])
        #expect(out["match"] == nil, "the old key was left behind to be ignored later")
        #expect(out["matchProcessName"] == nil)
    }

    /// The mark is the glyph beside the row. Losing it in migration leaves
    /// the agent showing a fallback icon, which looks like a missing asset
    /// rather than a dropped setting.
    @Test("Presentation keys move rather than disappearing")
    func presentationKeysMove() throws {
        let out = try migrate(v0)
        let presentation = try #require(out["presentation"] as? [String: Any])
        #expect(presentation["mark"] as? String == "synthetic-glyph")
        #expect(presentation["fallbackName"] as? String == "Synthetic Agent")
        #expect(out["mark"] == nil)
    }

    @Test("The migrated document carries the current format version")
    func versionIsStamped() throws {
        #expect(try migrate(v0)["formatVersion"] as? Int
                == HarnessConfig.currentFormatVersion)
    }

    /// A file somebody has half-migrated by hand carries both forms, and the
    /// runtime unions them whether or not the file says so. Leaving the old
    /// key would mean a matcher the file no longer shows is still claiming
    /// processes — the over-broad matcher problem, arrived at by accident.
    /// So the two are merged into the new key and the old one is removed.
    @Test("Both forms are merged into the new key, and the old one goes")
    func bothFormsMerge() throws {
        var mixed = v0
        mixed["process"] = ["pathContains": ["/edited/by/hand/"]]
        let out = try migrate(mixed)
        let process = try #require(out["process"] as? [String: Any])
        #expect(process["pathContains"] as? [String]
                == ["/edited/by/hand/", "/synthetic/versions/"],
                "the new value leads, and nothing was lost")
        #expect(out["match"] == nil, "the superseded key is cleared away")
    }

    @Test("A fragment present in both forms is not duplicated")
    func mergeDeduplicates() throws {
        var mixed = v0
        mixed["process"] = ["pathContains": ["/synthetic/versions/"]]
        let out = try migrate(mixed)
        let process = try #require(out["process"] as? [String: Any])
        #expect(process["pathContains"] as? [String] == ["/synthetic/versions/"])
    }

    @Test("A document already current is returned unchanged")
    func currentIsUntouched() throws {
        var already = v0
        already["formatVersion"] = HarnessConfig.currentFormatVersion
        already["process"] = ["pathContains": ["/synthetic/"]]
        already.removeValue(forKey: "match")
        already.removeValue(forKey: "matchProcessName")
        let out = try migrate(already)
        #expect((out["process"] as? [String: Any])?["pathContains"] as? [String]
                == ["/synthetic/"])
    }

    /// Nothing to move is not a failure: a v0 file with no presentation keys
    /// must not gain an empty block.
    @Test("A document with nothing to move gains no empty sections")
    func nothingToMove() throws {
        let plain: [String: Any] = ["id": "s", "name": "S",
                                    "source": ["kind": "none", "path": ""]]
        let out = try migrate(plain)
        #expect(out["presentation"] == nil, "an empty presentation block was invented")
        // Nor an empty matcher. `pathContains: []` reads as a rule that was
        // configured and matches nothing, which is a different thing from a
        // harness that never declared one.
        let process = out["process"] as? [String: Any] ?? [:]
        #expect(process["pathContains"] == nil, "an empty matcher was invented")
        #expect(process["names"] == nil)
    }
}

/// A migration must not be a filter.
///
/// `migrateV0toV1` starts from the document it was given and moves the keys
/// it knows, so anything it has never heard of survives by construction. That
/// is the property worth holding rather than the implementation: a migration
/// that rebuilt from a list of known keys would silently drop every field
/// added after it was written, and a user's edited descriptor would come back
/// from an upgrade quietly smaller.
@Suite("Migration keeps what it does not recognise")
struct MigrationPreservationTests {

    private func migrate(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        let result = try HarnessConfigMigration.migrate(data)
        return try #require(
            try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
    }

    /// Fields added to the format after this migration was written. A v0 file
    /// carrying one is unusual but entirely legal — somebody edits an old
    /// descriptor to use a new feature — and losing it on upgrade would be
    /// the worst kind of quiet.
    @Test("A field newer than the migration survives it")
    func newerFieldsSurvive() throws {
        let migrated = try migrate([
            "formatVersion": 0, "id": "old", "name": "Old",
            "match": ["/old"],
            "source": ["kind": "none", "path": ""],
            "quota": ["command": "agy", "args": ["-p", "/usage"],
                      "method": "GET",
                      "windows": ["list": "data", "usedPercent": "pct"]],
            "capabilities": ["instruction": ["probe": "content",
                                             "project": [".github/instructions"],
                                             "fileSuffixes": [".instructions.md"]]],
        ])
        let quota = try #require(migrated["quota"] as? [String: Any])
        #expect(quota["command"] as? String == "agy")
        #expect(quota["args"] as? [String] == ["-p", "/usage"])
        #expect(quota["method"] as? String == "GET")
        let rule = try #require((migrated["capabilities"] as? [String: Any])?["instruction"]
                                as? [String: Any])
        #expect(rule["fileSuffixes"] as? [String] == [".instructions.md"])
    }

    /// Including a key nothing in this project has ever defined, which is
    /// what a descriptor from a future version looks like to an older build.
    @Test("A key this version has never heard of survives")
    func unknownKeysSurvive() throws {
        let migrated = try migrate([
            "formatVersion": 0, "id": "old", "name": "Old",
            "match": ["/old"],
            "source": ["kind": "none", "path": ""],
            "somethingFromLater": ["nested": true],
        ])
        #expect((migrated["somethingFromLater"] as? [String: Any])?["nested"] as? Bool == true,
                "an unrecognised field was dropped by the migration")
    }

}

/// The SDK's decoder is written out by hand, one line per field.
///
/// It has to be: `$schema` is optional metadata and a Swift default is not a
/// Codable decoding default, so the synthesised initialiser would reject
/// valid authoring documents. The cost of writing it out is that a field
/// added to the type and not to the decoder comes back nil in silence — the
/// same alignment failure as the validator's key list, one file along, and
/// invisible in exactly the same way.
///
/// Re-encoding catches every such omission at once: a field the decoder skips
/// is a field the second encoding does not carry.
@Suite("Every field the SDK writes, the SDK reads back")
struct SDKDecoderCompletenessTests {

    private func populated() -> HarnessConfig {
        var config = HarnessConfig(
            id: "round", name: "Round",
            process: .init(pathContains: ["/round"], names: ["round"],
                           argv0Contains: ["/round/"]),
            source: .init(kind: .jsonl, path: "~/.round", glob: "*.jsonl"),
            map: .init(cwd: "cwd", model: "model", sessionID: "id"))
        config.detached = true
        config.multiSession = true
        var selection = HarnessConfig.Selection(path: "~/.round/state", glob: "*.json",
                                                records: "tabs", id: "id")
        selection.encodedJSON = true
        config.selection = selection
        var quota = HarnessConfig.Quota(endpoint: "https://example.invalid/u",
                                        windows: .init(list: "data"))
        quota.windows.usedPercent = "pct"
        quota.method = "POST"
        quota.body = ["scope": "current"]
        quota.setupHint = "Put your key somewhere"
        quota.verified = false
        config.quota = quota
        var rule = HarnessConfig.CapabilityRule(probe: .content, project: ["AGENTS.md"])
        rule.fileSuffixes = [".md"]
        config.capabilities = ["instruction": rule]
        config.idleAfter = 45
        config.staleAfter = 900
        config.note = "a note"
        config.enabled = true
        config.presentation = HarnessConfig.Presentation(
            mark: "round", fallbackName: "Round", sourceLabel: "Its own words")
        config.compatibility = HarnessConfig.Compatibility(level: .declared)
        return config
    }

    /// Encode, decode, encode again. Anything the decoder skipped is missing
    /// from the second document, whatever the first one said.
    @Test("A fully populated configuration survives a decode")
    func everyFieldSurvivesADecode() throws {
        let first = try populated().encoded()
        let decoded = try JSONDecoder().decode(HarnessConfig.self, from: first)
        let second = try decoded.encoded()

        let before = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let after = try #require(JSONSerialization.jsonObject(with: second) as? [String: Any])
        let lost = Set(before.keys).subtracting(after.keys)
        #expect(lost.isEmpty, Comment(rawValue:
            "the decoder drops \(lost.sorted()) — they are written and never read back"))
    }

    /// And the values, not merely the keys: a field decoded into the wrong
    /// place would keep the key and change the document.
    @Test("The re-encoded document matches the original byte for byte")
    func reEncodingIsIdentical() throws {
        let first = try populated().encoded()
        let decoded = try JSONDecoder().decode(HarnessConfig.self, from: first)
        #expect(try decoded.encoded() == first,
                "a field came back somewhere other than where it was written")
    }

    /// The reason the decoder is hand-written in the first place.
    @Test("A document with no $schema still decodes")
    func schemaIsOptional() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "id": "no-schema", "name": "No Schema",
            "process": ["pathContains": ["/x"]],
            "source": ["kind": "none", "path": ""],
        ])
        let decoded = try JSONDecoder().decode(HarnessConfig.self, from: data)
        #expect(decoded.id == "no-schema")
        #expect(decoded.schema == "../harness.schema.json",
                "the default that a synthesised decoder would not apply")
    }
}
