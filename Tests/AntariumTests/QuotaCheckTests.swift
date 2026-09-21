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
        // And a balance without a currency is money of unknown denomination.
        #expect(try check { $0["windows"] = ["single": "c", "balance": "amount"] } != 0)
        #expect(try check {
            $0["windows"] = ["single": "c", "balance": "amount", "currency": "  "]
        } != 0, "whitespace is not a currency")
        for shape in [["root": "usage", "percentRemaining": "left"],
                      ["root": "usage", "used": "n", "limit": "cap"],
                      ["single": "credits", "balance": "amount", "currency": "USD"]] {
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

/// OpenRouter reports two lifetime figures and no balance.
///
/// `data.total_credits` is everything ever added to the account and
/// `data.total_usage` everything ever spent, so the meter is spend against
/// purchases: empty after a top-up, full when the credits are gone. There is
/// no remaining-balance field, and the window map cannot subtract, which is
/// why this is a meter where the other credit providers draw an amount.
@Suite("OpenRouter charts spend against purchases")
struct OpenRouterQuotaTests {

    private func descriptor() throws -> HarnessDescriptor {
        let url = try #require(AppResources.bundle.url(
            forResource: "openrouter", withExtension: "json", subdirectory: "harnesses"))
        return try HarnessDocument.decode(Data(contentsOf: url)).descriptor
    }

    /// The endpoint answers 403 to an ordinary inference key and only a
    /// management key works. Reading the conventional OPENROUTER_API_KEY
    /// would take the key most people have and fail with it for ever, which
    /// is the degraded shipping docs/ECOSYSTEM.md rules out.
    @Test("The key is read from a file and never from the usual variable")
    func credentialIsFileOnly() throws {
        let credential = try #require(try descriptor().quota?.credential)
        #expect(credential.kind == "textFile")
        #expect(credential.name == nil,
                "an inference key would be picked up and 403 for ever")
        #expect(credential.path == "~/.antarium/keys/openrouter")
    }

    @Test("The hint names the file and says which key belongs in it")
    func hintNamesTheRightKey() throws {
        let hint = try #require(try descriptor().quota?.setupHint)
        #expect(hint.contains("~/.antarium/keys/openrouter"))
        #expect(hint.lowercased().contains("management"),
                "a user would put an inference key there and see 403 for ever")
        #expect(hint.count <= 48)
    }

    @Test("Spend is charted against purchases, not against a balance")
    func mapsUsedOverLimit() throws {
        let windows = try #require(try descriptor().quota?.windows)
        #expect(windows.used == "data.total_usage")
        #expect(windows.limit == "data.total_credits")
        #expect(windows.balance == nil, "there is no remaining figure to chart")
    }

    /// The figures themselves have not been seen against a live account, and
    /// the row says so rather than presenting them as confirmed.
    @Test("The numbers are declared unverified")
    func unverified() throws {
        #expect(try descriptor().quota?.verified != true)
    }

    private func snapshot(credits: Double, usage: Double) throws -> Snapshot {
        let provider = try #require(DescriptorProvider(try descriptor()))
        return try provider.makeSnapshot(
            ["data": ["total_credits": credits, "total_usage": usage]])
    }

    @Test("A quarter spent reads as a quarter")
    func quarterSpent() throws {
        let gauge = try #require(try snapshot(credits: 100, usage: 25).gauges.first)
        #expect(abs(gauge.used - 0.25) < 0.0001)
        #expect(gauge.title == "Credits")
        #expect(gauge.hasMeter, "a meter, because there are two figures to make one from")
    }

    /// An account that has never added credits would divide by zero. "Nothing
    /// of nothing" is not nought per cent, and a full green meter would be
    /// the worst of the available wrong answers.
    @Test("An account with no credits reports nothing rather than a figure")
    func noCreditsIsNotZeroPercent() {
        #expect(throws: (any Error).self) { _ = try snapshot(credits: 0, usage: 0) }
    }

    @Test("Exhausted credits read as full, not as absent")
    func exhaustedReadsFull() throws {
        let gauge = try #require(try snapshot(credits: 40, usage: 40).gauges.first)
        #expect(abs(gauge.used - 1.0) < 0.0001)
    }
}

/// Moonshot's balance, and the currency it does not state.
///
/// The API returns no currency field. The mapping used to answer "USD" for a
/// descriptor that declared none, which turns a CNY balance into a dollar
/// figure wrong by an exchange rate — the mistake the deepseek harness
/// already carries a note about. The decoder refuses a balance without a
/// currency now, so this descriptor has to say what it means and why.
@Suite("Moonshot charts the figure the service itself gates on")
struct MoonshotQuotaTests {

    private func descriptor() throws -> HarnessDescriptor {
        let url = try #require(AppResources.bundle.url(
            forResource: "moonshot", withExtension: "json", subdirectory: "harnesses"))
        return try HarnessDocument.decode(Data(contentsOf: url)).descriptor
    }

    private func snapshot(_ data: [String: Any]) throws -> Snapshot {
        let provider = try #require(DescriptorProvider(try descriptor()))
        return try provider.makeSnapshot(["code": 0, "status": true, "data": data])
    }

    /// The service says requests start failing once `available_balance`
    /// reaches zero, so that is the number worth watching — not the cash and
    /// voucher halves it is made of, which would be two bars for one fact.
    @Test("The gated figure is charted, not the halves it is made of")
    func chartsAvailableBalance() throws {
        let windows = try #require(try descriptor().quota?.windows)
        #expect(windows.balance == "data.available_balance")
        let gauges = try snapshot(["available_balance": 10.0,
                                   "voucher_balance": 7.0, "cash_balance": 3.0]).gauges
        #expect(gauges.count == 1, "the halves were charted as their own rows")
        #expect(gauges.first?.amount?.value == 10.0)
    }

    /// A balance cannot honestly be a bar: pinning it to full would paint the
    /// same green meter whether fifty dollars or two cents remained.
    @Test("A balance draws its figure and no meter")
    func balanceHasNoMeter() throws {
        let gauge = try #require(try snapshot(["available_balance": 49.58894]).gauges.first)
        #expect(gauge.hasMeter == false)
        #expect(gauge.amount?.currency == "USD")
    }

    /// Nought is a reading. Dropping it would make an account that has run
    /// out look exactly like one that could not be reached.
    @Test("An exhausted account reads nought rather than vanishing")
    func exhaustedIsARreading() throws {
        let gauge = try #require(try snapshot(["available_balance": 0.0]).gauges.first)
        #expect(gauge.amount?.value == 0.0)
    }

    @Test("A reply with no balance charts nothing")
    func missingBalanceChartsNothing() {
        #expect(throws: (any Error).self) { _ = try snapshot([:]) }
    }

    /// The currency is declared on evidence rather than stated by the API, so
    /// the figures are not presented as confirmed.
    @Test("The numbers are declared unverified")
    func unverified() throws {
        #expect(try descriptor().quota?.verified != true)
    }

    /// This is the API platform. The kimi harness reads the Kimi Code CLI's
    /// transcripts. One is an account and the other is a conversation, so
    /// neither counts the other — the double-counting rule that keeps
    /// aggregators out does not apply here, and a test says so because the
    /// two names look like they ought to collide.
    @Test("It does not overlap the Kimi CLI harness")
    func doesNotOverlapKimi() throws {
        let moonshot = try descriptor()
        let url = try #require(AppResources.bundle.url(
            forResource: "kimi", withExtension: "json", subdirectory: "harnesses"))
        let kimi = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
        #expect(moonshot.id != kimi.id)
        #expect(moonshot.source.kind == .none, "the account harness reads no sessions")
        #expect(kimi.quota == nil, "the CLI harness charts no quota")
    }
}

/// Synthetic is the first of these that is a proper meter with a reset.
///
/// The other credit providers count money down and have nothing to fill a bar
/// against. This one reports a request ceiling, the requests spent against it
/// and when it renews — so the row can say both how full it is and when that
/// stops mattering, which is what every native provider's window does and no
/// descriptor-backed one did.
@Suite("Synthetic charts requests against a subscription ceiling")
struct SyntheticQuotaTests {

    private func descriptor() throws -> HarnessDescriptor {
        let url = try #require(AppResources.bundle.url(
            forResource: "synthetic", withExtension: "json", subdirectory: "harnesses"))
        return try HarnessDocument.decode(Data(contentsOf: url)).descriptor
    }

    private func snapshot(limit: Any, requests: Any,
                          renews: String = "2026-10-21T14:36:14.288Z") throws -> Snapshot {
        let provider = try #require(DescriptorProvider(try descriptor()))
        return try provider.makeSnapshot(
            ["subscription": ["limit": limit, "requests": requests, "renewsAt": renews]])
    }

    @Test("A fifth spent reads as a fifth, with the renewal attached")
    func partlySpent() throws {
        let gauge = try #require(try snapshot(limit: 100, requests: 20).gauges.first)
        #expect(abs(gauge.used - 0.2) < 0.0001)
        #expect(gauge.title == "Subscription")
        #expect(gauge.hasMeter)
        #expect(gauge.resetsAt != nil, "a window that renews must say when")
    }

    /// The renewal is read from the response rather than guessed from a
    /// period length, which is the difference between a row that is right
    /// after a plan change and one that is right until somebody changes plan.
    @Test("The renewal is the one the service states")
    func renewalComesFromTheResponse() throws {
        let stated = try #require(UsageHTTP.parseDate("2027-03-04T05:06:07.000Z"))
        let gauge = try #require(
            try snapshot(limit: 10, requests: 1,
                         renews: "2027-03-04T05:06:07.000Z").gauges.first)
        #expect(gauge.resetsAt == stated)
    }

    /// An account with no subscription has a ceiling of nought. Nought of
    /// nothing is not nought per cent, and an empty bar would say the user
    /// had a plan with room left in it.
    @Test("No subscription charts nothing rather than an empty bar")
    func noSubscriptionChartsNothing() {
        #expect(throws: (any Error).self) { _ = try snapshot(limit: 0, requests: 0) }
    }

    @Test("An exhausted subscription reads full rather than vanishing")
    func exhaustedReadsFull() throws {
        let gauge = try #require(try snapshot(limit: 135, requests: 135).gauges.first)
        #expect(abs(gauge.used - 1.0) < 0.0001)
    }

    /// The key is an ordinary API key, so the variable is read when there is
    /// one — unlike OpenRouter, where the conventional variable holds the
    /// wrong kind of key and is deliberately ignored.
    @Test("The key comes from the variable or the file")
    func credentialReadsBoth() throws {
        let credential = try #require(try descriptor().quota?.credential)
        #expect(credential.kind == "env")
        #expect(credential.name == "SYNTHETIC_API_KEY")
        #expect(credential.path == "~/.antarium/keys/synthetic")
    }

    @Test("The numbers are declared unverified")
    func unverified() throws {
        #expect(try descriptor().quota?.verified != true)
    }
}

/// Not every usage API is a GET.
///
/// Codebuff posts to /api/v1/usage and Kimi's server endpoint is a POST whose
/// windows nest two levels deep. Both were unreachable by a model that could
/// only describe a GET, for a reason with nothing to do with whether their
/// mapping was expressible — the same shape as the command quota, one layer
/// out.
@Suite("A quota endpoint can be posted to", .serialized)
struct PostQuotaTests {

    private func decode(_ quota: [String: Any]) throws -> HarnessDescriptor {
        var full: [String: Any] = ["windows": ["list": "data", "usedPercent": "pct"]]
        full.merge(quota) { _, new in new }
        let object: [String: Any] = [
            "formatVersion": 1, "id": "post-quota", "name": "Post Quota",
            "process": [:], "source": ["kind": "none", "path": ""], "quota": full]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    @Test("A declared POST is what gets resolved")
    func postIsResolved() throws {
        let quota = try #require(try decode([
            "endpoint": "https://example.invalid/u", "method": "POST",
            "body": ["scope": "current"]]).quota)
        #expect(quota.resolvedMethod == .post)
        #expect(quota.body == ["scope": "current"])
    }

    /// Absent means GET, which is what every descriptor written so far
    /// assumes — adding the field must not change any of them.
    @Test("An undeclared method is a GET")
    func defaultIsGet() throws {
        let quota = try #require(try decode(["endpoint": "https://example.invalid/u"]).quota)
        #expect(quota.resolvedMethod == .get)
        #expect(quota.body == nil)
    }

    @Test("The method is read whatever its case", arguments: ["POST", "post", "Post"])
    func caseInsensitive(_ spelling: String) throws {
        let quota = try #require(try decode([
            "endpoint": "https://example.invalid/u", "method": spelling]).quota)
        #expect(quota.resolvedMethod == .post)
    }

    /// A typo reads as GET, and a descriptor that meant to post would fetch
    /// the wrong way and report whatever a GET to that path returns. Refused
    /// rather than defaulted.
    @Test("A method that is neither is refused", arguments: ["PUT", "DELETE", "PSOT", ""])
    func unknownMethodIsRefused(_ spelling: String) {
        #expect(throws: (any Error).self) {
            try decode(["endpoint": "https://example.invalid/u", "method": spelling])
        }
    }

    /// A body on a GET would be written, shipped and never sent. Refusing it
    /// is the difference between a descriptor that does not work and one that
    /// looks like it does.
    @Test("A body without a POST is refused")
    func bodyNeedsPost() {
        #expect(throws: (any Error).self) {
            try decode(["endpoint": "https://example.invalid/u", "body": ["a": "b"]])
        }
        #expect(throws: (any Error).self) {
            try decode(["endpoint": "https://example.invalid/u", "method": "GET",
                        "body": ["a": "b"]])
        }
    }

    @Test("A body that is not flat strings is refused")
    func bodyMustBeFlatStrings() {
        #expect(throws: (any Error).self) {
            try decode(["endpoint": "https://example.invalid/u", "method": "POST",
                        "body": ["nested": ["a": "b"]]])
        }
    }

    /// A command reads no endpoint, so it has no method to declare. Fields
    /// that belong to the other form are refused rather than ignored, because
    /// a descriptor carrying a method it will never use reads as if it uses
    /// it.
    @Test("A command quota declares no method or body")
    func commandTakesNeither() {
        #expect(throws: (any Error).self) {
            try decode(["command": "agy", "method": "POST"])
        }
        #expect(throws: (any Error).self) {
            try decode(["command": "agy", "body": ["a": "b"]])
        }
    }

    /// Every shipped descriptor predates the field and must still be a GET —
    /// adding a way to post is not a reason for anything to start posting.
    @Test("No shipped descriptor changed method")
    func shippedAreAllGet() throws {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        var checked = 0
        for url in urls {
            let descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            guard let quota = descriptor.quota, quota.command == nil else { continue }
            #expect(quota.resolvedMethod == .get,
                    Comment(rawValue: "\(descriptor.id) posts"))
            checked += 1
        }
        #expect(checked >= 8, "only \(checked) endpoint quotas were checked")
    }
}

/// A source field the declared kind never reads.
///
/// The key list catches a typo. It cannot catch a field spelled correctly and
/// ignored — a `limit` on a SQLite source, which bounds newest *files* and so
/// means nothing where there is one file, or a `query` on a JSONL one. Both
/// passed `--check` clean while doing nothing, which is the same silence that
/// reported `quota.command` as no field at all, from the other side.
@Suite("Source fields that do not apply are reported")
struct SourceFieldApplicabilityTests {

    /// Stated against the table rather than by running the checker, because
    /// the checker prints and the table is the rule.
    @Test("A file-only field does not apply to SQLite or command sources",
          arguments: ["glob", "limit", "journal", "pathFields", "manifest"])
    func fileOnlyFields(_ field: String) throws {
        let kinds = try #require(HarnessCheck.sourceFieldKinds[field])
        #expect(kinds == [.json, .jsonl])
    }

    @Test("A SQLite-only field does not apply to a file source",
          arguments: ["query", "columns"])
    func sqliteOnlyFields(_ field: String) throws {
        #expect(try #require(HarnessCheck.sourceFieldKinds[field]) == [.sqlite])
    }

    @Test("A command-only field does not apply to a file source",
          arguments: ["args", "refreshEvery", "root"])
    func commandOnlyFields(_ field: String) throws {
        #expect(try #require(HarnessCheck.sourceFieldKinds[field]) == [.command])
    }

    /// `path` and `kind` are read by everything and must not be in the table,
    /// or every descriptor would be warned about its own path.
    @Test("Fields every kind reads are not in the table", arguments: [
        "kind", "path", "filter", "paths",
    ])
    func universalFieldsAreAbsent(_ field: String) {
        #expect(HarnessCheck.sourceFieldKinds[field] == nil,
                "\(field) would be reported as inapplicable on every harness")
    }

    /// And no shipped harness declares a field its own kind ignores, which is
    /// what makes this safe to warn about rather than merely describe.
    @Test("No shipped harness declares a field its kind ignores")
    func shippedHarnessesAreClean() throws {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        var checked = 0
        for url in urls {
            let data = try Data(contentsOf: url)
            let descriptor = try HarnessDocument.decode(data).descriptor
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let source = (object["source"] as? [String: Any]) ?? [:]
            for (key, kinds) in HarnessCheck.sourceFieldKinds where source[key] != nil {
                #expect(kinds.contains(descriptor.source.kind), Comment(rawValue:
                    "\(descriptor.id) is \(descriptor.source.kind.rawValue) and declares \(key)"))
            }
            checked += 1
        }
        #expect(checked >= 20, "only \(checked) harnesses were checked")
    }
}

/// The same question for `selection`, which has its own kind and its own
/// three sets of fields.
///
/// Read off the three functions in `SessionSelection` rather than guessed:
/// the jsonFiles and command paths share the record filter, and the sqlite
/// path returns ids straight out of a column without consulting it.
@Suite("Selection fields that do not apply are reported")
struct SelectionFieldApplicabilityTests {

    @Test("Reading files is the only kind with a glob and records",
          arguments: ["glob", "records", "encodedJSON"])
    func fileOnly(_ field: String) throws {
        #expect(try #require(HarnessCheck.selectionFieldKinds[field]) == [.jsonFiles])
    }

    @Test("Querying is the only kind with a query and a column",
          arguments: ["query", "column"])
    func sqliteOnly(_ field: String) throws {
        #expect(try #require(HarnessCheck.selectionFieldKinds[field]) == [.sqlite])
    }

    @Test("Running something is the only kind with a command",
          arguments: ["command", "args", "root"])
    func commandOnly(_ field: String) throws {
        #expect(try #require(HarnessCheck.selectionFieldKinds[field]) == [.command])
    }

    /// The two that are shared, and are shared by exactly two of the three.
    /// A sqlite selection takes its ids from a column, so naming a field path
    /// or a filter there does nothing — and claiming they were universal
    /// would make this check say nothing about them at all.
    @Test("The record filter belongs to the two kinds that read records",
          arguments: ["id", "filter"])
    func sharedByTwo(_ field: String) throws {
        #expect(try #require(HarnessCheck.selectionFieldKinds[field])
                == [.jsonFiles, .command])
    }

    @Test("Fields every kind reads are not in the table", arguments: ["kind", "path"])
    func universalFieldsAreAbsent(_ field: String) {
        #expect(HarnessCheck.selectionFieldKinds[field] == nil)
    }

    /// No shipped harness declares one its own kind ignores.
    @Test("No shipped selection declares a field its kind ignores")
    func shippedSelectionsAreClean() throws {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        var checked = 0
        for url in urls {
            let data = try Data(contentsOf: url)
            let descriptor = try HarnessDocument.decode(data).descriptor
            guard let kind = descriptor.sessionSelection?.kind else { continue }
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let selection = (object["selection"] as? [String: Any]) ?? [:]
            for (key, kinds) in HarnessCheck.selectionFieldKinds where selection[key] != nil {
                #expect(kinds.contains(kind), Comment(rawValue:
                    "\(descriptor.id) selects by \(kind.rawValue) and declares \(key)"))
            }
            checked += 1
        }
        #expect(checked >= 1, "no shipped harness declares a selection")
    }
}

/// The two applicability tables are consulted, not merely present.
///
/// Both are tested as data, which says the rule is right and nothing about
/// whether `--check` applies it. Checked in the source because the checker
/// prints its findings rather than returning them, and a mutation removing
/// the loop either fails to compile or removes the only thing it does.
@Suite("The applicability tables are used")
struct ApplicabilityWiringTests {

    private func checker() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/Core/HarnessCheck.swift"), encoding: .utf8)
    }

    /// Derived rather than counted. The first version of the assertion below
    /// said "exactly two", and adding the third table broke it for the reason
    /// it exists to prevent — a rule that lists its subjects covers only the
    /// ones that prompted it.
    static let tables: [(table: String, prefix: String)] = [
        ("sourceFieldKinds", "source."),
        ("selectionFieldKinds", "selection."),
        ("credentialFieldKinds", "quota.credential."),
    ]

    @Test("Every table is read, and every one produces a warning",
          arguments: ApplicabilityWiringTests.tables)
    func tableIsConsulted(_ pair: (table: String, prefix: String)) throws {
        let text = try checker()
        let uses = text.components(separatedBy: pair.table).count - 1
        #expect(uses >= 2, "\(pair.table) is declared and never read")
        #expect(text.contains("warn(\"\(pair.prefix)\\(key) is only read for"),
                "\(pair.table) is read and says nothing")
    }

    /// And the warning names which kinds do read it, because "ignored" on its
    /// own leaves the author to work out where the field belongs.
    @Test("The warning says which kinds read the field")
    func warningNamesTheKinds() throws {
        let text = try checker()
        let naming = text.components(separatedBy: "is only read for a \\(names)").count - 1
        #expect(naming == Self.tables.count, Comment(rawValue:
            "\(naming) of \(Self.tables.count) warnings name the kinds that read the field"))
    }

    /// And the list above is not empty, because a parameterised test over one
    /// would pass having checked nothing.
    @Test("There are tables to check")
    func tablesExist() {
        #expect(Self.tables.count >= 3)
    }
}

/// The third object with a `kind`: a quota credential.
///
/// One of its fields already had a hard rule — `requires` is refused at
/// decode on anything but a `jsonFile`, because a guard that silently does
/// nothing is worse than no guard. The other four had none, so an `env`
/// credential could carry a `field`, a `command` and its `args` and be told
/// nothing about any of them.
@Suite("Credential fields that do not apply are reported")
struct CredentialFieldApplicabilityTests {

    @Test("Each field belongs to the kinds that read it", arguments: [
        ("name", Set(["env"])),
        ("field", Set(["jsonFile"])),
        ("command", Set(["command"])),
        ("args", Set(["command"])),
    ])
    func singleKindFields(_ pair: (field: String, kinds: Set<String>)) throws {
        #expect(try #require(HarnessCheck.credentialFieldKinds[pair.field]) == pair.kinds)
    }

    /// The one that is shared, and by three of the four. An `env` credential
    /// falls back to a file when the variable is unset — which is what makes
    /// those providers work at all when the app is launched from Finder — so
    /// warning about `path` there would be wrong.
    @Test("A path belongs to every kind that reads a file, including env")
    func pathIsSharedByThree() throws {
        #expect(try #require(HarnessCheck.credentialFieldKinds["path"])
                == ["env", "textFile", "jsonFile"])
    }

    /// `requires` is deliberately absent: the decoder refuses it outright, so
    /// a warning here would be unreachable.
    @Test("The field with a hard rule is not also warned about")
    func requiresIsNotInTheTable() {
        #expect(HarnessCheck.credentialFieldKinds["requires"] == nil)
        #expect(HarnessCheck.credentialFieldKinds["kind"] == nil)
    }

    @Test("A credential declaring a field its kind ignores is refused at decode only for requires")
    func requiresStillRefused() {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "c", "name": "C", "process": [:],
            "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": "https://example.invalid/u",
                      "credential": ["kind": "env", "name": "FOO",
                                     "requires": ["a": "b"]],
                      "windows": ["list": "data", "usedPercent": "pct"]]]
        #expect(throws: (any Error).self) {
            try HarnessDocument.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test("No shipped credential declares a field its kind ignores")
    func shippedCredentialsAreClean() throws {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        var checked = 0
        for url in urls {
            let data = try Data(contentsOf: url)
            let descriptor = try HarnessDocument.decode(data).descriptor
            guard let kind = descriptor.quota?.credential?.kind else { continue }
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let credential = ((object["quota"] as? [String: Any])?["credential"]
                              as? [String: Any]) ?? [:]
            for (key, kinds) in HarnessCheck.credentialFieldKinds where credential[key] != nil {
                #expect(kinds.contains(kind), Comment(rawValue:
                    "\(descriptor.id) has a \(kind) credential declaring \(key)"))
            }
            checked += 1
        }
        #expect(checked >= 8, "only \(checked) credentials were checked")
    }
}

/// A credential that belongs in the URL rather than in a header.
///
/// A self-hosted proxy in front of an agent — LiteLLM, and the several like
/// it — asks for the key being queried as a query parameter. `{token}` was
/// substituted into headers and POST bodies and not into the endpoint, which
/// left the whole class undescribable: not by a shipped descriptor, which
/// cannot know the host anyway, and not by somebody writing their own, which
/// is the part that mattered. docs/ECOSYSTEM.md recorded the shipping problem
/// and missed this one.
@Suite("A token can go in the endpoint")
struct EndpointTokenTests {

    @Test("The placeholder is replaced with the credential")
    func placeholderIsFilled() throws {
        let url = try #require(DescriptorProvider.requestURL(
            "http://127.0.0.1:4000/key/info?key={token}", token: "sk-abc123"))
        #expect(url.absoluteString == "http://127.0.0.1:4000/key/info?key=sk%2Dabc123")
    }

    /// A key carrying a separator would otherwise end the parameter early and
    /// send the rest as something else — or quietly ask about a different
    /// key, which is the reading that looks like an answer.
    @Test("A credential carrying URL punctuation cannot break out of its parameter",
          arguments: ["a&b=c", "a?b", "a#b", "a/b", "a b", "a+b", "a%b"])
    func punctuationIsEncoded(token: String) throws {
        let url = try #require(DescriptorProvider.requestURL(
            "https://example.invalid/info?key={token}&scope=plan", token: token))
        let query = try #require(url.query)
        #expect(query.hasSuffix("&scope=plan"), "the token swallowed the rest of the query")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "key" }?.value == token,
                "the token did not survive the round trip intact")
    }

    /// An endpoint that names no token is left exactly as written, or every
    /// existing descriptor would be going through a different code path.
    @Test("An endpoint with no placeholder is untouched")
    func withoutPlaceholder() throws {
        let raw = "https://api.example.invalid/v1/usage?scope=plan"
        #expect(DescriptorProvider.requestURL(raw, token: "sk-abc")?.absoluteString == raw)
    }

    /// `URL(string:)` accepts far more than a usable endpoint — it percent-
    /// encodes a line of prose rather than refusing it — so the guard that
    /// matters is the one at the request, not here. Asserted where it lives,
    /// since substituting a token must not be a way past it.
    @Test("An endpoint with no host is still refused at the request")
    func stillRefusesNonURLs() throws {
        #expect(DescriptorProvider.requestURL("", token: "t") == nil)
        let prose = try #require(DescriptorProvider.requestURL("not a url at all", token: "t"))
        #expect(throws: ProviderError.self) { _ = try UsageHTTP.checkedURL(prose) }
        // And a token in the query does not smuggle an unusable scheme past it.
        let ftp = try #require(DescriptorProvider.requestURL(
            "ftp://example.invalid/info?key={token}", token: "sk-abc"))
        #expect(throws: ProviderError.self) { _ = try UsageHTTP.checkedURL(ftp) }
        // The loopback case a self-hosted proxy actually uses is allowed.
        let local = try #require(DescriptorProvider.requestURL(
            "http://127.0.0.1:4000/key/info?key={token}", token: "sk-abc"))
        #expect(throws: Never.self) { _ = try UsageHTTP.checkedURL(local) }
    }

    /// The token must not be able to bend the request somewhere else — the
    /// encoding is what keeps a credential a value rather than syntax.
    @Test("A credential cannot redirect the request to another host")
    func cannotChangeTheHost() throws {
        let url = try #require(DescriptorProvider.requestURL(
            "https://intended.invalid/info?key={token}",
            token: "x@evil.invalid/steal?y="))
        #expect(url.host == "intended.invalid", "the token moved the request to \(url.host ?? "—")")
    }
}

/// Usage scoped under an account the URL has to name.
///
/// `GET /v1/accounts/{account_id}/quotas` is a common shape, and
/// docs/ECOSYSTEM.md turned one down for it: a descriptor declares one
/// endpoint, not a call to discover the identifier for the next. It recorded
/// that the first half would recur — plenty of vendors scope usage this way
/// — which is what makes it worth solving rather than noting.
///
/// The identifier is usually written beside the token, which is where the
/// Codex provider reads its own from. That file the credential already opens
/// is the answer for the common case; a discovery call is a bigger thing and
/// still is not possible.
@Suite("A quota scoped under an account", .serialized)
struct AccountScopedQuotaTests {

    private func write(_ object: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private func provider(credential: [String: Any],
                          endpoint: String = "https://api.example.invalid/v1/accounts/{account}/quotas")
        throws -> DescriptorProvider {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "scoped-\(UUID().uuidString)", "name": "Scoped",
            "process": [:], "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": endpoint, "credential": credential,
                      "windows": ["list": "data", "usedPercent": "pct"]],
        ]
        let d = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        return try #require(DescriptorProvider(d))
    }

    @Test("The account id is read from the file beside the token")
    func accountIsRead() throws {
        let file = try write(["token": "sk-abc", "account_id": "acct-42"])
        defer { try? FileManager.default.removeItem(at: file) }
        let p = try provider(credential: ["kind": "jsonFile", "path": file.path,
                                          "field": "token", "accountField": "account_id"])
        #expect(p.account() == "acct-42")
    }

    /// A numeric id is an ordinary id. Reading only strings would report a
    /// file that names one plainly as naming none.
    @Test("An account id written as a number is still an account id")
    func numericAccount() throws {
        let file = try write(["token": "sk-abc", "org": 90210])
        defer { try? FileManager.default.removeItem(at: file) }
        let p = try provider(credential: ["kind": "jsonFile", "path": file.path,
                                          "field": "token", "accountField": "org"])
        #expect(p.account() == "90210")
    }

    @Test("It lands in the path where the placeholder is")
    func accountFillsTheURL() throws {
        let url = try #require(DescriptorProvider.requestURL(
            "https://api.example.invalid/v1/accounts/{account}/quotas",
            token: "sk-abc", account: "acct-42"))
        #expect(url.absoluteString == "https://api.example.invalid/v1/accounts/acct%2D42/quotas")
    }

    /// Encoded like the token, so an id carrying a separator stays one path
    /// component rather than becoming another.
    @Test("An account id cannot add path segments of its own")
    func accountCannotTraverse() throws {
        let url = try #require(DescriptorProvider.requestURL(
            "https://intended.invalid/v1/accounts/{account}/quotas",
            token: "t", account: "../../admin"))
        #expect(url.host == "intended.invalid")
        // Asserted on what goes on the wire. `url.path` hands back the
        // decoded form, so it shows the dots whatever the encoding did; the
        // request itself carries one escaped segment, which a server reads as
        // a name rather than as a walk.
        #expect(!url.absoluteString.contains("/../"),
                "the id walked out of its segment: \(url.absoluteString)")
        #expect(url.absoluteString.contains("%2E%2E%2F"),
                "the id was not escaped: \(url.absoluteString)")
    }

    /// A header value is not percent-encoded, because encoding it there would
    /// send the escape sequence rather than the value.
    @Test("A header carries the account as written")
    func headerIsNotEncoded() {
        #expect(DescriptorProvider.filled("Account {account}", token: "t",
                                          account: "acct 42", forURL: false)
                == "Account acct 42")
        // Only the substituted value is encoded, never the template around
        // it: the template is the descriptor author's own text, and escaping
        // their separators would send the escape sequence as the separator.
        #expect(DescriptorProvider.filled("Account {account}", token: "t",
                                          account: "acct 42", forURL: true)
                == "Account acct%2042")
    }

    /// The two failures a descriptor author can make, both refused where it
    /// is written rather than at the first fetch.
    @Test("Asking for an account without a file to read it from is refused")
    func accountFieldNeedsAJSONFile() {
        #expect(throws: (any Error).self) {
            try provider(credential: ["kind": "env", "name": "TOKEN",
                                      "accountField": "account_id"])
        }
    }

    @Test("Using the placeholder without declaring the field is refused")
    func placeholderNeedsTheField() throws {
        let file = try write(["token": "sk-abc"])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) {
            try provider(credential: ["kind": "jsonFile", "path": file.path, "field": "token"])
        }
    }

    /// A credential that fails its `requires` guards is not this vendor's,
    /// and neither is the account id sitting next to it.
    @Test("An account id in a file that is not this vendor's is not read")
    func requiresGuardsTheAccountToo() throws {
        let file = try write(["token": "sk-abc", "account_id": "acct-42",
                              "vendor": "somebody-else"])
        defer { try? FileManager.default.removeItem(at: file) }
        let p = try provider(credential: ["kind": "jsonFile", "path": file.path,
                                          "field": "token", "accountField": "account_id",
                                          "requires": ["vendor": "example"]])
        #expect(p.account() == nil, "another vendor's account id was read")
    }

    /// An endpoint with no placeholder is untouched by any of this, or every
    /// descriptor that ships today would be taking a different path.
    @Test("A descriptor that names no account is unaffected")
    func withoutAccount() {
        #expect(DescriptorProvider.filled("https://x.invalid/u?key={token}", token: "sk-1",
                                          account: nil, forURL: true)
                == "https://x.invalid/u?key=sk%2D1")
    }
}
