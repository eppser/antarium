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

/// The response body is capped at 2 MiB. What gets built out of it was not
/// capped at all — and a gauge is not a cheap object: it becomes a menu bar
/// line, a dashboard row and an alert evaluation. These bound the derived
/// work, not the transfer.
@Suite("A usage response cannot make the app build unbounded work", .serialized)
struct ResponseBoundsTests {

    private func provider(_ quota: [String: Any]) throws -> DescriptorProvider {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "bounds-\(UUID().uuidString)", "name": "Bounds",
            "process": [:], "source": ["kind": "none", "path": ""], "quota": quota]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        return try #require(DescriptorProvider(descriptor))
    }

    @Test("A list of thousands of windows yields a bounded number of gauges")
    func listIsBounded() throws {
        let p = try provider(["endpoint": "https://example.invalid/u",
                              "windows": ["list": "data", "usedPercent": "pct"]])
        let windows = (0..<5_000).map { ["pct": Double($0 % 100), "id": "w\($0)"] }
        let snapshot = try p.makeSnapshot(["data": windows])
        #expect(snapshot.gauges.count == DescriptorProvider.maxWindows)
    }

    @Test("An object of thousands of windows is bounded the same way")
    func objectIsBounded() throws {
        let p = try provider(["endpoint": "https://example.invalid/u",
                              "windows": ["root": "data", "usedPercent": "pct"]])
        var container: [String: Any] = [:]
        for i in 0..<5_000 { container["w\(i)"] = ["pct": Double(i % 100)] }
        let snapshot = try p.makeSnapshot(["data": container])
        #expect(snapshot.gauges.count == DescriptorProvider.maxWindows)
    }

    /// A cap that is below what real plans report would be a bug of its own,
    /// so the ordinary case has to keep coming through untouched.
    @Test("A response of ordinary size is not truncated")
    func ordinaryResponseIsWhole() throws {
        let p = try provider(["endpoint": "https://example.invalid/u",
                              "windows": ["list": "data", "usedPercent": "pct"]])
        let windows = (0..<4).map { ["pct": Double($0 * 10), "id": "w\($0)"] }
        let snapshot = try p.makeSnapshot(["data": windows])
        #expect(snapshot.gauges.count == 4)
    }

    @Test("A title the server sends cannot be arbitrarily long")
    func titleIsClamped() throws {
        let p = try provider(["endpoint": "https://example.invalid/u",
                              "windows": ["list": "data", "usedPercent": "pct",
                                          "title": "name"]])
        let long = String(repeating: "A", count: 100_000)
        let snapshot = try p.makeSnapshot(["data": [["pct": 10.0, "name": long]]])
        let gauge = try #require(snapshot.gauges.first)
        #expect(gauge.title.count == DescriptorProvider.maxResponseText)
    }

    @Test("A currency code the server sends cannot be arbitrarily long")
    func currencyIsClamped() throws {
        let p = try provider(["endpoint": "https://example.invalid/u",
                              "windows": ["list": "data", "balance": "amount",
                                          "currency": "code"]])
        let long = String(repeating: "C", count: 100_000)
        let snapshot = try p.makeSnapshot(["data": [["amount": 5.0, "code": long]]])
        let gauge = try #require(snapshot.gauges.first)
        #expect(gauge.amount?.currency.count == DescriptorProvider.maxResponseText)
    }

    @Test("A window key the server sends cannot be arbitrarily long")
    func keyIsClamped() throws {
        let p = try provider(["endpoint": "https://example.invalid/u",
                              "windows": ["list": "data", "usedPercent": "pct",
                                          "key": ["type"]]])
        let long = String(repeating: "K", count: 100_000)
        let snapshot = try p.makeSnapshot(["data": [["pct": 10.0, "type": long]]])
        let gauge = try #require(snapshot.gauges.first)
        #expect(gauge.id.count == DescriptorProvider.maxResponseText)
    }

    /// Descriptor text is trusted local configuration and is deliberately not
    /// clamped; only what arrives over the network is.
    @Test("A label the descriptor declares is left as the author wrote it")
    func descriptorLabelsAreNotClamped() throws {
        let long = String(repeating: "L", count: 200)
        let p = try provider(["endpoint": "https://example.invalid/u",
                              "windows": ["list": "data", "usedPercent": "pct",
                                          "key": ["type"], "labels": ["t": long]]])
        let snapshot = try p.makeSnapshot(["data": [["pct": 10.0, "type": "t"]]])
        #expect(snapshot.gauges.first?.title == long)
    }
}

/// Credential files are written by another application, so they are input.
/// Every native provider reads its own through `BoundedFile`; the descriptor
/// path read `~/.claude/settings.json` with no cap at all, which is the sort
/// of difference that survives precisely because both halves work.
@Suite("A descriptor credential file is read within a bound", .serialized)
struct DescriptorCredentialBoundTests {

    private func provider(_ kind: String, contents: Data) throws -> (DescriptorProvider, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-\(UUID()).txt")
        try contents.write(to: file)
        var credential: [String: Any] = ["kind": kind, "path": file.path]
        if kind == "jsonFile" { credential["field"] = "token" }
        let object: [String: Any] = [
            "formatVersion": 1, "id": "bounded-\(UUID().uuidString)", "name": "Bounded",
            "process": [:], "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": "https://example.invalid/usage",
                      "credential": credential,
                      "windows": ["list": "data", "usedPercent": "percentage"]]]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        return (try #require(DescriptorProvider(descriptor)), file)
    }

    /// Padding inside the JSON rather than after it, so the file is still
    /// valid: a reader that rejects it is applying a size limit and not
    /// merely failing to parse.
    private func oversizedJSON() -> Data {
        let padding = String(repeating: "x", count: DescriptorProvider.maxCredentialBytes)
        return Data(#"{"token":"synthetic","pad":"\#(padding)"}"#.utf8)
    }

    @Test("An ordinary JSON credential is still read")
    func jsonWithinBound() throws {
        ConfiguredProbe.invalidate()
        let (p, file) = try provider("jsonFile", contents: Data(#"{"token":"synthetic"}"#.utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(p.isConfigured, "a normal credential file stopped being readable")
    }

    @Test("A JSON credential file past the bound is not read")
    func jsonBeyondBound() throws {
        ConfiguredProbe.invalidate()
        let (p, file) = try provider("jsonFile", contents: oversizedJSON())
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(p.isConfigured == false, "an unbounded read of a credential file")
    }

    @Test("An ordinary text credential is still read")
    func textWithinBound() throws {
        ConfiguredProbe.invalidate()
        let (p, file) = try provider("textFile", contents: Data("synthetic-token\n".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(p.isConfigured)
    }

    @Test("A text credential file past the bound is not read")
    func textBeyondBound() throws {
        ConfiguredProbe.invalidate()
        let (p, file) = try provider(
            "textFile",
            contents: Data(String(repeating: "x", count: DescriptorProvider.maxCredentialBytes + 1).utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(p.isConfigured == false, "an unbounded read of a credential file")
    }

    /// The bound matches what Codex and Gemini use. If one moves and the
    /// other does not, the two halves have drifted again.
    @Test("The bound is the one the native providers use")
    func boundMatchesNativeProviders() {
        #expect(DescriptorProvider.maxCredentialBytes == 256 * 1_024)
    }
}

/// A quota that comes from a command rather than an endpoint.
///
/// Some agents have stopped answering over HTTP. Antigravity's embedded
/// server began rejecting every tokenless request once its CLI stopped
/// publishing the CSRF token it generates, and the working path became
/// `agy -p /usage --output-format json`. A model that can only describe an
/// endpoint cannot describe that, so an agent whose mapping is perfectly
/// expressible still needed native code — the opposite of what descriptors
/// are for.
@Suite("A quota can be read from a command")
struct CommandQuotaTests {

    private func decode(_ quota: [String: Any]) throws -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "cmd-quota", "name": "Command Quota",
            "process": [:], "source": ["kind": "none", "path": ""], "quota": quota]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    private var windows: [String: Any] {
        ["list": "data", "usedPercent": "pct"]
    }

    @Test("A command quota decodes and carries its argv")
    func commandDecodes() throws {
        let d = try decode(["command": "agy", "args": ["-p", "/usage", "--output-format", "json"],
                            "windows": windows])
        let quota = try #require(d.quota)
        #expect(quota.command == "agy")
        #expect(quota.args == ["-p", "/usage", "--output-format", "json"])
        #expect(quota.endpoint == nil)
    }

    /// Both would leave which one wins to the order of an `if`, and neither
    /// is a quota block that does anything — it would decode, ship, and
    /// report nothing at all.
    @Test("Declaring both an endpoint and a command is refused")
    func bothIsRefused() {
        #expect(throws: (any Error).self) {
            try decode(["endpoint": "https://example.invalid/u", "command": "agy",
                        "windows": windows])
        }
    }

    @Test("Declaring neither is refused")
    func neitherIsRefused() {
        #expect(throws: (any Error).self) { try decode(["windows": windows]) }
    }

    /// argv, never a shell. A separator in the program name is the shape of
    /// an injected path rather than a name to resolve on PATH.
    @Test("A command that is a path or a line is refused", arguments: [
        "/usr/local/bin/agy", "agy --usage", "sh -c agy", "../agy",
    ])
    func commandMustBeAName(_ command: String) {
        #expect(throws: (any Error).self) {
            try decode(["command": command, "windows": windows])
        }
    }

    @Test("Arguments must be strings")
    func argsMustBeStrings() {
        #expect(throws: (any Error).self) {
            try decode(["command": "agy", "args": [1, 2], "windows": windows])
        }
    }

    /// Fields that belong to the other form are refused rather than ignored,
    /// because a descriptor carrying headers it will never send reads as if
    /// it sends them.
    @Test("Endpoint-only and command-only fields do not cross over")
    func fieldsDoNotCrossOver() {
        #expect(throws: (any Error).self) {
            try decode(["command": "agy", "headers": ["X": "1"], "windows": windows])
        }
        #expect(throws: (any Error).self) {
            try decode(["endpoint": "https://example.invalid/u", "args": ["-p"],
                        "windows": windows])
        }
    }

    /// The whole point of the shape: the mapping is checked against a
    /// synthetic payload, with nothing installed. What the command would have
    /// printed is exactly what `makeSnapshot` is handed.
    @Test("The mapping is verified from a payload, with no CLI present")
    func mappingIsCheckedOffline() throws {
        let d = try decode(["command": "agy", "args": ["-p", "/usage"],
                            "windows": ["list": "groups", "usedPercent": "pct",
                                        "key": ["id"], "labels": ["five-hour": "Session"]]])
        let provider = try #require(DescriptorProvider(d))
        let snapshot = try provider.makeSnapshot(
            ["groups": [["id": "five-hour", "pct": 42.0]]])
        let gauge = try #require(snapshot.gauges.first)
        #expect(gauge.title == "Session")
        #expect(abs(gauge.used - 0.42) < 0.0001)
    }

    /// A CLI that is not installed is not a signed-out account. Reporting
    /// "sign in" for a missing program sends the user to fix the wrong thing.
    @Test("A command that is not on this Mac is not configured, not signed out")
    func missingCommandIsNotConfigured() throws {
        let d = try decode(["command": "definitelynotarealprogramxyz",
                            "windows": windows])
        let provider = try #require(DescriptorProvider(d))
        #expect(provider.isConfigured == false)
    }
}

/// What a quota command's output is allowed to be.
///
/// These run real programs that every Mac has, because the bounds being
/// checked are on the subprocess rather than on a parser: a `yes`-shaped
/// command flooding stdout, and one that fails. Neither can be reached by
/// handing `makeSnapshot` a dictionary.
@Suite("A quota command's output is bounded and its failure is a failure")
struct CommandQuotaOutputTests {

    private func provider(command: String, args: [String]) throws -> DescriptorProvider {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "cmd-out-\(UUID().uuidString)", "name": "Command Output",
            "process": [:], "source": ["kind": "none", "path": ""],
            "quota": ["command": command, "args": args,
                      "windows": ["list": "data", "usedPercent": "pct"]]]
        let d = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        return try #require(DescriptorProvider(d))
    }

    /// Each of these asserts *which* failure, not merely that one happened.
    /// Every one of these paths ends in a throw whatever goes wrong, so
    /// "it threw" is satisfied by removing the check being tested — which is
    /// exactly what the first version of these did, and two mutations
    /// survived them.
    private func failure(_ p: DescriptorProvider) async -> ProviderError? {
        do {
            _ = try await p.fetch()
            return nil
        } catch let error as ProviderError {
            return error
        } catch {
            return nil
        }
    }

    /// Half a JSON document is not a smaller set of windows. A truncated
    /// reply is refused rather than parsed, so a flood cannot become a
    /// plausible-looking figure.
    @Test("A command that floods stdout is refused, not truncated and parsed")
    func floodIsRefused() async throws {
        let p = try provider(command: "head",
                             args: ["-c", "\(DescriptorProvider.maxCommandOutput * 2)", "/dev/zero"])
        #expect(await failure(p) == .badResponse(
            "Command Output printed more than \(DescriptorProvider.maxCommandOutput / 1_024) KB of usage."))
    }

    /// An exit code is the difference between "no figures" and "figures that
    /// happen to be empty" — and the message has to say so. This first read
    /// "printed more than 512 KB", because the check was written against
    /// `Shell.Result.completeOutput`, which is `succeeded && !stdoutTruncated`
    /// and so is false for every kind of failure. A command that exits 1
    /// printing nothing was reported as one that printed too much.
    @Test("A command that fails is a failure, not an empty reading")
    func failureIsAFailure() async throws {
        let p = try provider(command: "false", args: [])
        #expect(await failure(p) == .badResponse(
            "Command Output's usage command exited with 1."),
                "an optional leaked into a message the user reads")
    }

    @Test("A command that prints something other than JSON is a failure")
    func nonJSONIsAFailure() async throws {
        let p = try provider(command: "echo", args: ["not json at all"])
        #expect(await failure(p) == .badResponse(
            "Command Output's usage command did not print JSON."))
    }

    /// And the ordinary path: a command that prints the payload is read.
    @Test("A command that prints the usage JSON is read")
    func ordinaryOutputIsRead() async throws {
        let p = try provider(command: "echo",
                             args: [#"{"data":[{"pct":30.0}]}"#])
        let snapshot = try await p.fetch()
        #expect(abs((snapshot.gauges.first?.used ?? 0) - 0.30) < 0.0001)
    }
}

/// An environment variable is not a credential a menu bar app can rely on.
///
/// An app started from Finder inherits the launchd session environment, not a
/// shell's — the same fact the copilot harness already relies on when it
/// reads `gh auth token` instead of a variable. Three shipped providers read
/// only a variable, so in the ordinary installation they said "not signed in"
/// for ever, and nothing could tell that from an account that really was
/// signed out.
@Suite("An env credential falls back to a file", .serialized)
struct EnvCredentialFallbackTests {

    private func provider(name: String?, path: String?) throws -> DescriptorProvider {
        var credential: [String: Any] = ["kind": "env"]
        if let name { credential["name"] = name }
        if let path { credential["path"] = path }
        let object: [String: Any] = [
            "formatVersion": 1, "id": "env-\(UUID().uuidString)", "name": "Env",
            "process": [:], "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": "https://example.invalid/u", "credential": credential,
                      "windows": ["list": "data", "usedPercent": "pct"]]]
        let d = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        return try #require(DescriptorProvider(d))
    }

    private func keyFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("key-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("The file is read when the variable is unset")
    func fileIsReadWhenVariableIsAbsent() throws {
        ConfiguredProbe.invalidate()
        let file = try keyFile("synthetic-key\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let p = try provider(name: "ANTARIUM_NO_SUCH_VARIABLE", path: file.path)
        #expect(p.isConfigured, "a key file next to an unset variable read as signed out")
    }

    /// Trailing newlines are what a `printf ... > file` leaves behind, and a
    /// bearer token with one on the end is rejected by the service rather
    /// than by us, which is a much worse place to find out.
    @Test("Whitespace around the key is not part of the key")
    func keyIsTrimmed() throws {
        ConfiguredProbe.invalidate()
        let file = try keyFile("  synthetic-key\n\n")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try provider(name: "ANTARIUM_NO_SUCH_VARIABLE", path: file.path).isConfigured)
    }

    @Test("An empty key file is not a credential")
    func emptyFileIsNotAKey() throws {
        ConfiguredProbe.invalidate()
        let file = try keyFile("   \n")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try provider(name: "ANTARIUM_NO_SUCH_VARIABLE", path: file.path)
                    .isConfigured == false)
    }

    @Test("No variable and no file is still not signed in")
    func neitherIsNotConfigured() throws {
        ConfiguredProbe.invalidate()
        #expect(try provider(name: "ANTARIUM_NO_SUCH_VARIABLE",
                             path: "/nonexistent/antarium/key").isConfigured == false)
        ConfiguredProbe.invalidate()
        #expect(try provider(name: "ANTARIUM_NO_SUCH_VARIABLE", path: nil)
                    .isConfigured == false)
    }

    /// The file is a fallback, not a replacement: a terminal launch that has
    /// the variable must keep using it, or a user who rotates a key in their
    /// shell would go on being charted against a stale one in a file.
    @Test("The variable wins when both are present")
    func variableWinsOverFile() throws {
        ConfiguredProbe.invalidate()
        let file = try keyFile("from-the-file")
        defer { try? FileManager.default.removeItem(at: file) }
        // PATH is set in every process, so it stands in for "a variable that
        // is there" without this test setting one.
        let p = try provider(name: "PATH", path: file.path)
        #expect(p.isConfigured)
        #expect(p.token() == ProcessInfo.processInfo.environment["PATH"],
                "the file was preferred to a variable that was set")
    }

    /// Bounded like every other credential read, because another program
    /// wrote the file.
    @Test("An oversized key file is not read")
    func oversizedKeyFileIsRefused() throws {
        ConfiguredProbe.invalidate()
        let file = try keyFile(String(repeating: "k",
                                      count: DescriptorProvider.maxCredentialBytes + 1))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try provider(name: "ANTARIUM_NO_SUCH_VARIABLE", path: file.path)
                    .isConfigured == false)
    }
}
