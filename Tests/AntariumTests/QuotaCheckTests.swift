import Foundation
import Testing
@testable import Antarium

/// `--check` is what the README tells a harness author to run before
/// restarting. For a quota-only descriptor the quota block is the entire point
/// of the file, and it used to report nothing about it: an endpoint of
/// "not a url" passed with no problems and failed at the first fetch instead,
/// which is the wrong moment and the wrong place to learn it.
@Suite("Harness checking covers the quota block")
struct QuotaCheckTests {

    private func check(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Int32 {
        var quota: [String: Any] = [
            "endpoint": "https://example.invalid/usage",
            "credential": ["kind": "env", "name": "EXAMPLE_TOKEN"],
            "windows": ["root": "usage", "usedPercent": "percent"],
            "setupHint": "Add your API key to example.json.",
        ]
        mutate(&quota)
        let document: [String: Any] = [
            "formatVersion": 1, "id": "example", "name": "Example",
            "process": [:], "source": ["kind": "none", "path": ""],
            "quota": quota,
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-check-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return HarnessCheck.run(url.path)
    }

    @Test("A well-formed quota block passes")
    func validQuotaPasses() throws {
        #expect(try check() == 0)
    }

    @Test("An endpoint that is not an https URL is a problem, not a runtime surprise")
    func endpointMustBeHTTPS() throws {
        #expect(try check { $0["endpoint"] = "not a url" } != 0)
        #expect(try check { $0["endpoint"] = "http://example.invalid/usage" } != 0)
        #expect(try check { $0["endpoint"] = "https:///nohost" } != 0)
    }

    @Test("A credential missing the field its kind needs is a problem")
    func credentialsNeedTheirCompanions() throws {
        #expect(try check { $0["credential"] = ["kind": "env"] } != 0)
        #expect(try check { $0["credential"] = ["kind": "textFile"] } != 0)
        #expect(try check { $0["credential"] = ["kind": "jsonFile", "path": "~/x.json"] } != 0)
        #expect(try check { $0["credential"] = ["kind": "command"] } != 0)
        #expect(try check { $0["credential"] = ["kind": "telepathy", "name": "X"] } != 0)
        // A quota endpoint that needs no credential at all is legitimate.
        #expect(try check { $0["credential"] = nil } == 0)
    }

    @Test("Windows that name no figure cannot chart anything")
    func windowsMustDeclareAFigure() throws {
        #expect(try check { $0["windows"] = ["root": "usage"] } != 0)
        // `used` without `limit` is a ratio with no denominator.
        #expect(try check { $0["windows"] = ["root": "usage", "used": "n"] } != 0)
        for shape in [["root": "usage", "percentRemaining": "left"],
                      ["root": "usage", "used": "n", "limit": "cap"],
                      ["single": "credits", "balance": "amount"]] {
            #expect(try check { $0["windows"] = shape } == 0, "rejected a valid shape: \(shape)")
        }
    }

    @Test("A badge the menu bar cannot fit is a problem")
    func badgesMustFit() throws {
        #expect(try check {
            $0["windows"] = ["root": "usage", "usedPercent": "p", "badges": ["w": "SESSION"]]
        } != 0)
        #expect(try check {
            $0["windows"] = ["root": "usage", "usedPercent": "p", "badges": ["w": ""]]
        } != 0)
        #expect(try check {
            $0["windows"] = ["root": "usage", "usedPercent": "p", "badges": ["w": "5H"]]
        } == 0)
    }
}

/// Z.ai's plan runs through Claude Code, so its token is whatever sits in
/// `~/.claude/settings.json` under `env.ANTHROPIC_AUTH_TOKEN`. That field is
/// not Z.ai's — Kimi, MiniMax, a corporate gateway and a plain Anthropic key
/// all use it. Before `requires`, any of them read as a Z.ai sign-in, scored
/// for a first-run menu bar slot, and had the token put in an
/// `Authorization: Bearer` header to api.z.ai.
@Suite("A shared credential file must prove whose token it holds", .serialized)
struct SharedCredentialTests {

    private func provider(settings: String, requires: [String: String]?) throws
        -> (DescriptorProvider, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID()).json")
        try Data(settings.utf8).write(to: file)
        var credential: [String: Any] = [
            "kind": "jsonFile", "path": file.path, "field": "env.ANTHROPIC_AUTH_TOKEN"]
        if let requires { credential["requires"] = requires }
        let object: [String: Any] = [
            "formatVersion": 1, "id": "shared-\(UUID().uuidString)", "name": "Shared",
            "process": [:], "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": "https://example.invalid/usage",
                      "credential": credential,
                      "windows": ["list": "data", "usedPercent": "percentage"]]]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        return (try #require(DescriptorProvider(descriptor)), file)
    }

    private static let zaiSettings = #"""
    {"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic","ANTHROPIC_AUTH_TOKEN":"synthetic-token"}}
    """#
    private static let kimiSettings = #"""
    {"env":{"ANTHROPIC_BASE_URL":"https://api.moonshot.ai/anthropic","ANTHROPIC_AUTH_TOKEN":"synthetic-token"}}
    """#

    @Test("A token routed to another vendor is not reported as a sign-in here")
    func otherVendorIsNotSignedIn() throws {
        ConfiguredProbe.invalidate()
        let (p, file) = try provider(settings: Self.kimiSettings,
                                     requires: ["env.ANTHROPIC_BASE_URL": "z.ai"])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(p.isConfigured == false)
    }

    @Test("The vendor's own token is still found")
    func ownTokenIsFound() throws {
        ConfiguredProbe.invalidate()
        let (p, file) = try provider(settings: Self.zaiSettings,
                                     requires: ["env.ANTHROPIC_BASE_URL": "z.ai"])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(p.isConfigured == true)
    }

    /// The test above passes trivially if the field is simply unreadable, so
    /// this pins that the same file without the guard *does* read as signed
    /// in — the guard is what makes the difference, not a broken path.
    @Test("Without the guard the same foreign token reads as a sign-in")
    func guardIsWhatMakesTheDifference() throws {
        ConfiguredProbe.invalidate()
        let (p, file) = try provider(settings: Self.kimiSettings, requires: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(p.isConfigured == true)
    }

    @Test("A missing discriminator fails closed rather than open")
    func absentFieldIsRefused() throws {
        ConfiguredProbe.invalidate()
        let (p, file) = try provider(settings: #"{"env":{"ANTHROPIC_AUTH_TOKEN":"synthetic-token"}}"#,
                                     requires: ["env.ANTHROPIC_BASE_URL": "z.ai"])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(p.isConfigured == false)
    }

    @Test("A guard that would never be read is rejected at decode",
          arguments: [
            ["kind": "env", "name": "X", "requires": ["a": "b"]] as [String: Any],
            ["kind": "textFile", "path": "/tmp/x", "requires": ["a": "b"]],
            ["kind": "jsonFile", "path": "/tmp/x", "field": "f", "requires": [:]],
            ["kind": "jsonFile", "path": "/tmp/x", "field": "f", "requires": ["a": ""]],
          ])
    func badGuardsAreRefused(_ credential: [String: Any]) throws {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "bad", "name": "Bad", "process": [:],
            "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": "https://example.invalid/u", "credential": credential,
                      "windows": ["list": "d", "usedPercent": "p"]]]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Swift.Error).self) { try HarnessDocument.decode(data) }
    }

    /// The reason any of this exists. If a shipped descriptor ever reads a
    /// credential out of a file another vendor also writes, it needs a guard.
    @Test("Every shipped credential is vendor-specific or guarded")
    func shippedCredentialsAreUnambiguous() throws {
        // Read from the bundle, not from HarnessDescriptor.all(), which
        // answers with whatever this Mac has seeded.
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        #expect(urls.count > 1, "an empty catalog would pass this trivially")
        let shared = ["/.claude/", "/.config/", "/.aws/", "/.netrc"]
        for url in urls {
            let descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            guard let credential = descriptor.quota?.credential,
                  credential.kind == "jsonFile" || credential.kind == "textFile",
                  let path = credential.path,
                  shared.contains(where: { path.contains($0) }) else { continue }
            let guarded = credential.requires?.isEmpty == false
            #expect(guarded, Comment(rawValue: "\(descriptor.id) reads a token from \(path), "
                    + "which is not its own file, with nothing to prove the token is its"))
        }
    }
}
