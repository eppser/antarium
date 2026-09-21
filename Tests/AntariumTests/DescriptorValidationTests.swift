import Foundation
import Testing
@testable import Antarium

/// Harness descriptors are the public extension point, and this is the layer
/// that refuses a malformed one. Every rule below could be deleted without
/// failing a single test: a blank id, an unsupported source kind, a path that
/// is not a string, and an unrecognised session binding were all accepted.
///
/// The messages matter as much as the refusals. They are what `--check`
/// prints to somebody writing a harness, who cannot see the decoder.
@Suite("Descriptor validation")
struct DescriptorValidationTests {

    private func decode(_ overrides: [String: Any?]) throws -> HarnessDescriptor {
        var document: [String: Any] = [
            "formatVersion": 1, "id": "example", "name": "Example",
            "process": [:], "source": ["kind": "none", "path": ""],
        ]
        for (key, value) in overrides {
            if let value { document[key] = value } else { document.removeValue(forKey: key) }
        }
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: document)).descriptor
    }

    private func message(_ overrides: [String: Any?]) -> String? {
        do { _ = try decode(overrides); return nil }
        catch let error as HarnessDocument.Error {
            if case .semantic(let text) = error { return text }
            return "\(error)"
        } catch { return "\(error)" }
    }

    @Test("A well-formed descriptor decodes")
    func validDocumentDecodes() throws {
        let descriptor = try decode([:])
        #expect(descriptor.id == "example")
        #expect(descriptor.source.kind == .none)
    }

    @Test("An id or name that is blank, absent or only spaces is refused")
    func identityMustBePresent() {
        for key in ["id", "name"] {
            #expect(message([key: nil])?.contains(key) == true,
                    "a missing \(key) was accepted")
            #expect(message([key: ""])?.contains(key) == true,
                    "an empty \(key) was accepted")
            #expect(message([key: "   \t "])?.contains(key) == true,
                    "a whitespace-only \(key) was accepted")
            // A number is not a name.
            #expect(message([key: 7]) != nil, "a non-string \(key) was accepted")
        }
    }

    @Test("Only the source kinds the reader implements are accepted")
    func sourceKindIsFromTheKnownSet() throws {
        for kind in ["jsonl", "json", "sqlite", "command", "none"] {
            let path = kind == "sqlite" ? "/tmp/x.sqlite" : ""
            var source: [String: Any] = ["kind": kind, "path": path]
            if kind == "jsonl" || kind == "json" { source["glob"] = "*.jsonl" }
            if kind == "command" { source["command"] = "/bin/echo" }
            // A SQLite source has nothing to read without a query, and the
            // decoder says so rather than producing a reader that returns
            // nothing.
            if kind == "sqlite" { source["query"] = "SELECT id FROM t"; source["columns"] = ["sessionID"] }
            #expect(throws: Never.self, "rejected a supported kind: \(kind)") {
                _ = try decode(["source": source])
            }
        }
        // Anything else is refused — but the point of the explicit check is
        // the message. Without it the Codable enum still refuses, with
        // "Cannot initialize Kind from invalid String value yaml" and a
        // decoding path, which is not something to show a harness author.
        for kind in ["yaml", "JSONL", "sql", ""] {
            let reported = message(["source": ["kind": kind, "path": ""]])
            #expect(reported != nil, "accepted source.kind \"\(kind)\"")
            let detail = reported ?? "nothing"
            #expect(reported?.contains("source.kind") == true,
                    "source.kind \"\(kind)\" was refused by the decoder rather than named: \(detail)")
            #expect(reported?.contains("Cannot initialize") != true,
                    "a raw decoding error reached the author for kind \"\(kind)\"")
        }
    }

    @Test("source.path is required, even when it is empty")
    func sourcePathMustBeAString() {
        // Empty is the documented value for none and command; absent is not
        // the same thing, and neither is a number.
        #expect(message(["source": ["kind": "none"]])?.contains("source.path") == true)
        #expect(message(["source": ["kind": "none", "path": 3]])?.contains("source.path") == true)
        #expect(message(["source": ["kind": "none", "path": ""]]) == nil)
    }

    @Test("An unrecognised session binding is refused, not ignored")
    func sessionBindingIsFromTheKnownSet() {
        // Silently ignoring it would mean a harness that thinks it requires
        // session evidence emitting rows that have none.
        let jsonlSource: [String: Any] = ["kind": "jsonl", "path": "/tmp/x", "glob": "*.jsonl"]
        #expect(message(["process": ["sessionBinding": "openSourceFile"],
                         "source": jsonlSource]) == nil)
        for binding in ["openFile", "whatever", ""] {
            let reported = message(["process": ["sessionBinding": binding],
                                    "source": jsonlSource])
            #expect(reported != nil, "accepted sessionBinding \"\(binding)\"")
            let detail = reported ?? "nothing"
            #expect(reported?.contains("sessionBinding") == true,
                    "sessionBinding \"\(binding)\" was refused without being named: \(detail)")
            #expect(reported?.contains("Cannot initialize") != true,
                    "a raw decoding error reached the author for binding \"\(binding)\"")
        }
        // And the binding needs a source it can actually bind to: naming an
        // open file is meaningless when the harness reads no files.
        #expect(message(["process": ["sessionBinding": "openSourceFile"]])?
            .contains("JSON") == true)
    }

    @Test("process and source are both required")
    func structuralSectionsAreRequired() {
        #expect(message(["process": nil]) != nil)
        #expect(message(["source": nil])?.contains("source") == true)
        // And they have to be objects, not something else that decodes.
        #expect(message(["process": "yes"]) != nil)
        #expect(message(["source": "none"]) != nil)
    }
}

/// `--check` is what a harness author runs before shipping a descriptor, and
/// what the release script runs over every shipped one. Its individual rules
/// are tested; that it actually *reports* them was not, so deleting a rule
/// from the run left the suite green.
@Suite("The descriptor checker reports what it finds", .serialized)
struct HarnessCheckReportingTests {

    private func check(_ object: [String: Any]) throws -> Int32 {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("check-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return HarnessCheck.run(file.path)
    }

    private var valid: [String: Any] {
        ["formatVersion": 1, "id": "check-fixture", "name": "Fixture",
         "process": [:], "source": ["kind": "none", "path": ""]]
    }

    @Test("A descriptor with nothing wrong with it passes")
    func validDescriptorPasses() throws {
        #expect(try check(valid) == 0, "the failures below would mean nothing otherwise")
    }

    /// A key the loader ignores is the quietest way to get a descriptor wrong:
    /// the file looks configured and the setting does nothing.
    @Test("A field the loader would ignore is reported")
    func unknownFieldIsReported() throws {
        var object = valid
        object["notAField"] = "value"
        #expect(try check(object) != 0)
    }

    @Test("An unknown field nested inside a block is reported")
    func nestedUnknownFieldIsReported() throws {
        var object = valid
        object["quota"] = ["endpoint": "https://example.invalid/u",
                           "windows": ["list": "d", "usedPercent": "p"],
                           "notAField": 1]
        #expect(try check(object) != 0)
    }

    @Test("A plaintext usage endpoint is reported")
    func plaintextEndpointIsReported() throws {
        var object = valid
        object["quota"] = ["endpoint": "http://example.invalid/u",
                           "windows": ["list": "d", "usedPercent": "p"]]
        #expect(try check(object) != 0)
    }

    @Test("A window that declares no figure is reported")
    func figurelessWindowIsReported() throws {
        var object = valid
        object["quota"] = ["endpoint": "https://example.invalid/u", "windows": ["list": "d"]]
        #expect(try check(object) != 0)
    }

    @Test("A file that is not a descriptor at all is reported")
    func nonDescriptorIsReported() throws {
        #expect(try check(["nothing": "useful"]) != 0)
    }
}
