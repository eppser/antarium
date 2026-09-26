import Foundation
import Testing
@testable import Antarium

/// The credential half of the same vocabulary.
///
/// `requires` is documented as a map of *field path* to required substring, and
/// `field` and `accountField` are read the same way — `zai` already declares
/// `env.ANTHROPIC_AUTH_TOKEN`. All three resolved flatly, so a filter in any of
/// them would have been accepted by `--check` and then matched nothing. Same
/// defect as `title`, one surface along, and found by asking the same question
/// of every remaining `FieldPath.lookup` call.
///
/// A filter earns its place here. A shared credential file holding one entry per
/// provider is the shape `requires` exists for in the first place: Z.ai's token
/// sits in a field that Kimi, MiniMax, a corporate gateway and a plain
/// Anthropic key all write too, and a file that lists them as an array cannot be
/// read at all without selecting the right entry.
@Suite("A credential field path resolves a filter written in it", .serialized)
struct CredentialPathFilterTests {

    /// A credential file in a temporary directory, removed after the body.
    private func withCredential(_ json: String,
                                _ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("credentials.json")
        try Data(json.utf8).write(to: file)
        try body(file.path)
    }

    private func provider(_ quota: String) throws -> DescriptorProvider {
        let document = Data("""
        {
          "formatVersion":\(HarnessDocument.currentVersion),
          "id":"credential-fixture","name":"Credential fixture",
          "process":{"pathContains":["/credential-fixture"]},
          "source":{"kind":"none","path":""},
          "quota":\(quota)
        }
        """.utf8)
        return try #require(DescriptorProvider(try HarnessDocument.decode(document).descriptor))
    }

    /// One entry per provider, the wanted one second so position cannot carry
    /// the assertion, and the decoy holding a token that must not be returned.
    private let accounts = #"""
    {"accounts":[
      {"provider":"other","token":"decoy-token","org":"decoy-org","base":"example.invalid"},
      {"provider":"zai","token":"real-token","org":"real-org","base":"api.z.ai"}
    ]}
    """#

    @Test("A filtered credential field reads the entry it names")
    func filteredField() throws {
        try withCredential(accounts) { path in
            let provider = try self.provider("""
            {"endpoint":"https://example.invalid/usage",
             "credential":{"kind":"jsonFile","path":"\(path)",
                           "field":"accounts[provider=zai].token"},
             "windows":{"single":"b","balance":"balance","currency":"USD"}}
            """)
            #expect(provider.token() == "real-token",
                    "a filtered credential field read the wrong entry")
        }
    }

    @Test("A filtered requires guard checks the entry it names")
    func filteredRequires() throws {
        try withCredential(accounts) { path in
            // The guard holds for the wanted entry.
            let ok = try self.provider("""
            {"endpoint":"https://example.invalid/usage",
             "credential":{"kind":"jsonFile","path":"\(path)",
                           "field":"accounts[provider=zai].token",
                           "requires":{"accounts[provider=zai].base":"z.ai"}},
             "windows":{"single":"b","balance":"balance","currency":"USD"}}
            """)
            #expect(ok.token() == "real-token", "a filtered requires guard failed a file it should pass")
            // And fails when asked of the entry that does not satisfy it, which
            // is what proves the filter selected rather than scanning.
            let refused = try self.provider("""
            {"endpoint":"https://example.invalid/usage",
             "credential":{"kind":"jsonFile","path":"\(path)",
                           "field":"accounts[provider=zai].token",
                           "requires":{"accounts[provider=other].base":"z.ai"}},
             "windows":{"single":"b","balance":"balance","currency":"USD"}}
            """)
            #expect(refused.token() == nil,
                    "the guard passed by reading an entry it was not pointed at")
        }
    }

    @Test("A filtered accountField reads the entry it names")
    func filteredAccountField() throws {
        try withCredential(accounts) { path in
            let provider = try self.provider("""
            {"endpoint":"https://example.invalid/usage/{account}",
             "credential":{"kind":"jsonFile","path":"\(path)",
                           "field":"accounts[provider=zai].token",
                           "accountField":"accounts[provider=zai].org"},
             "windows":{"single":"b","balance":"balance","currency":"USD"}}
            """)
            #expect(provider.account() == "real-org",
                    "a filtered accountField read the wrong entry")
        }
    }

    /// A guard that names nothing resolvable fails closed, which is the whole
    /// reason `requires` exists: an unrecognised setup is reported as not
    /// signed in rather than as this vendor and sent to it.
    @Test("A filter matching no entry fails the guard closed")
    func filterMatchingNothingFailsClosed() throws {
        try withCredential(accounts) { path in
            let provider = try self.provider("""
            {"endpoint":"https://example.invalid/usage",
             "credential":{"kind":"jsonFile","path":"\(path)",
                           "field":"accounts[provider=zai].token",
                           "requires":{"accounts[provider=absent].base":"z.ai"}},
             "windows":{"single":"b","balance":"balance","currency":"USD"}}
            """)
            #expect(provider.token() == nil,
                    "a guard naming an entry that is not there passed")
        }
    }

    /// And a plain dotted path still works, which is every shipped descriptor.
    @Test("A dotted credential field is still the field it names")
    func dottedFieldStillWorks() throws {
        try withCredential(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"flat-token"}}"#) { path in
            let provider = try self.provider("""
            {"endpoint":"https://example.invalid/usage",
             "credential":{"kind":"jsonFile","path":"\(path)",
                           "field":"env.ANTHROPIC_AUTH_TOKEN"},
             "windows":{"single":"b","balance":"balance","currency":"USD"}}
            """)
            #expect(provider.token() == "flat-token")
        }
    }

    /// `accountLabel` is a path into the reply, not the credential file.
    @Test("A filtered accountLabel reads the entry it names")
    func filteredAccountLabel() throws {
        let provider = try provider("""
        {"endpoint":"https://example.invalid/usage",
         "accountLabel":"plans[active=true].name",
         "windows":{"single":"b","balance":"balance","currency":"USD"}}
        """)
        let reply = #"""
        {"balance":4.20,
         "plans":[{"active":false,"name":"Old plan"},{"active":true,"name":"Business"}]}
        """#
        let json = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8))
                                    as? [String: Any])
        #expect(try provider.makeSnapshot(json).accountLabel == "Business",
                "a filtered accountLabel read the wrong plan")
    }

    /// The classification, held against the struct the same way the window
    /// block's is — so a credential field added without being thought about
    /// fails here rather than going unvalidated.
    @Test("Every credential field is either a path or named as not one")
    func everyFieldIsClassified() {
        var credential = HarnessDescriptor.Quota.Credential(kind: "jsonFile")
        credential.path = "/not/a/json/path"
        credential.field = "p-field"
        credential.name = "NOT_A_PATH"
        credential.command = "not-a-path"
        credential.args = ["not-a-path"]
        credential.requires = ["p-requires": "value"]
        credential.accountField = "p-accountField"
        let paths = Set(credential.fieldPaths)
        let excluded = HarnessDescriptor.Quota.Credential.nonPathFields
        let labels = Mirror(reflecting: credential).children.compactMap(\.label)
        #expect(labels.count == Mirror(reflecting: credential).children.count)
        for label in labels where !excluded.contains(label) {
            #expect(paths.contains("p-\(label)"),
                    Comment(rawValue: "credential.\(label) is neither in fieldPaths nor named "
                            + "in nonPathFields — a filter in it would go unvalidated"))
        }
        #expect(!paths.contains("/not/a/json/path"), "a filesystem path is not a field path")
        #expect(!paths.contains("NOT_A_PATH"), "an environment variable's name is not a path")
    }

    @Test("Every excluded credential name is a field that exists")
    func exclusionsExist() {
        let credential = HarnessDescriptor.Quota.Credential(kind: "env")
        let labels = Set(Mirror(reflecting: credential).children.compactMap(\.label))
        for name in HarnessDescriptor.Quota.Credential.nonPathFields {
            #expect(labels.contains(name),
                    Comment(rawValue: "nonPathFields names \(name), which is not a field"))
        }
    }

    /// And a malformed filter in a credential guard is refused where it is
    /// written, which is what asking the quota rather than the windows buys.
    @Test("A malformed filter in a credential path is refused", arguments: [
        #""field":"accounts[provider].token""#,
        #""field":"env.TOKEN","accountField":"accounts[=zai].org""#,
        #""field":"env.TOKEN","requires":{"accounts[provider=].base":"z.ai"}"#,
    ])
    func malformedCredentialPath(declaration: String) {
        let document = Data("""
        {
          "formatVersion":\(HarnessDocument.currentVersion),
          "id":"credential-bad","name":"Credential bad",
          "process":{"pathContains":["/credential-bad"]},
          "source":{"kind":"none","path":""},
          "quota":{"endpoint":"https://example.invalid/usage",
                   "credential":{"kind":"jsonFile","path":"/tmp/none.json",\(declaration)},
                   "windows":{"single":"b","balance":"balance","currency":"USD"}}
        }
        """.utf8)
        #expect(throws: HarnessDocument.Error.self,
                Comment(rawValue: "accepted \(declaration)")) {
            _ = try HarnessDocument.decode(document)
        }
    }

    @Test("A malformed filter in accountLabel is refused")
    func malformedAccountLabel() {
        let document = Data("""
        {
          "formatVersion":\(HarnessDocument.currentVersion),
          "id":"label-bad","name":"Label bad",
          "process":{"pathContains":["/label-bad"]},
          "source":{"kind":"none","path":""},
          "quota":{"endpoint":"https://example.invalid/usage",
                   "accountLabel":"plans[active].name",
                   "windows":{"single":"b","balance":"balance","currency":"USD"}}
        }
        """.utf8)
        #expect(throws: HarnessDocument.Error.self) { _ = try HarnessDocument.decode(document) }
    }
}
