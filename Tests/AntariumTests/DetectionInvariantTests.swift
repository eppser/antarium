import Foundation
import Testing
@testable import Antarium

/// Rules that tie two mechanisms together. Each one holds today; none of them
/// had anything keeping it that way, and all three fail silently — the symptom
/// is a plausible-looking row, not an error.
@Suite("Detection invariants across the shipped catalogue")
struct DetectionInvariantTests {

    private func bundled() throws -> [HarnessDescriptor] {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        return try urls.map { try HarnessDocument.decode(Data(contentsOf: $0)).descriptor }
    }

    /// `isAgent` is the predicate deciding whether a process gets measured at
    /// all. A process a descriptor claims but the predicate rejects reports
    /// 0 MB for ever, and an idle-looking agent is exactly what that resembles
    /// — the claude-code descriptor's own note says "miss one and its memory
    /// reads 0MB".
    ///
    /// The installation probes already describe real processes, with a
    /// documented source and a date. Holding the two against each other costs
    /// nothing and needs nothing installed.
    @Test("Every process a descriptor claims is one the scanner will measure")
    func claimedProcessesAreMeasured() throws {
        let descriptors = try bundled()
        // Built from the shipped catalogue, not from this Mac's seeded one.
        let fragments = descriptors.flatMap { $0.processRule.pathContains ?? [] }
        let names = Set(descriptors.flatMap(\.processNames))
        var checked = 0
        for descriptor in descriptors {
            for probe in descriptor.processRule.installationProbes ?? []
            where probe.expected {
                checked += 1
                let measured = [probe.path, probe.name, probe.argv0].contains {
                    AgentScan.isAgent($0, fragments: fragments, names: names)
                }
                #expect(measured, Comment(rawValue:
                    "\(descriptor.id) claims \(probe.method) installs but the scanner "
                    + "would not measure them, so their memory reads 0 MB"))
            }
        }
        #expect(checked > 10, "too few probes to have proved anything")
    }

    /// A probe that expects *no* match must not be measured either, or the
    /// test above passes against a predicate that says yes to everything.
    @Test("A process no descriptor claims is not measured")
    func unclaimedProcessesAreNotMeasured() throws {
        let descriptors = try bundled()
        let fragments = descriptors.flatMap { $0.processRule.pathContains ?? [] }
        let names = Set(descriptors.flatMap(\.processNames))
        var checked = 0
        for descriptor in descriptors {
            for probe in descriptor.processRule.installationProbes ?? []
            where !probe.expected {
                checked += 1
                let measured = [probe.path, probe.name, probe.argv0].contains {
                    AgentScan.isAgent($0, fragments: fragments, names: names)
                }
                #expect(!measured, Comment(rawValue:
                    "\(descriptor.id): \(probe.path) is documented as not this agent, "
                    + "yet the scanner treats it as one"))
            }
        }
        #expect(checked >= 1, "no negative probes ship, so this proved nothing")
    }
}

/// Caches the app writes are the app's to clean up — which is only safe while
/// the live filename and the cleanup list cannot name the same file.
@Suite("A cache version bump cannot delete the live cache")
struct CacheVersionTests {

    @Test("The live transcript cache is not in its own superseded list")
    func liveCacheIsNotSuperseded() {
        let live = TranscriptStats.cacheFilename
        let superseded = TranscriptStats.supersededCacheFilenames
        #expect(!superseded.contains(live),
                "\(live) is deleted on every launch, so history is re-read every time")
        #expect(!superseded.isEmpty, "an empty list would pass this trivially")
    }

    /// Bumping the version without extending the list orphans a file instead.
    /// Less serious than deleting the live one, and still the app's mess.
    @Test("Every earlier transcript cache version is cleaned up")
    func priorVersionsAreListed() {
        let live = TranscriptStats.cacheFilename
        let version = Int(live.replacingOccurrences(of: "transcripts-v", with: "")
                              .replacingOccurrences(of: ".json", with: "")) ?? 0
        #expect(version > 1, "expected a versioned filename, got \(live)")
        for earlier in 2..<version {
            #expect(TranscriptStats.supersededCacheFilenames.contains("transcripts-v\(earlier).json"),
                    Comment(rawValue: "transcripts-v\(earlier).json is left behind"))
        }
        #expect(TranscriptStats.supersededCacheFilenames.contains("transcripts.json"),
                "the original unversioned cache")
    }
}

/// Codex had three answers to "is this signed in": `isConfigured` asked
/// whether auth.json existed, `fetch` extracted a token four ways, and
/// `storedAuth` extracted it three — omitting `OPENAI_API_KEY`. A user whose
/// auth.json holds only that key got a working quota gauge and cloud tasks
/// reporting credentials unavailable, with nothing anywhere saying why.
@Suite("Codex gives one answer about being signed in", .serialized)
struct CodexCredentialTests {

    private func withCodexHome<T>(_ contents: String?, _ body: () -> T) -> T {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let contents {
            try? Data(contents.utf8).write(to: home.appendingPathComponent("auth.json"))
        }
        let previousHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        // The env fallbacks would otherwise answer for the file under test.
        let cleared = ["CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY"]
        let saved = cleared.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, _) in saved { unsetenv(key) }
        setenv("CODEX_HOME", home.path, 1)
        defer {
            if let previousHome { setenv("CODEX_HOME", previousHome, 1) } else { unsetenv("CODEX_HOME") }
            for (key, value) in saved where value != nil { setenv(key, value!, 1) }
            try? FileManager.default.removeItem(at: home)
        }
        ConfiguredProbe.invalidate()
        return body()
    }

    /// The exact shape that used to disagree.
    @Test("An API-key login is a sign-in everywhere, not only in the gauge")
    func apiKeyLoginIsConsistent() {
        withCodexHome(#"{"OPENAI_API_KEY":"synthetic-key"}"#) {
            #expect(CodexProvider().isConfigured)
            let stored = CodexProvider.storedAuth()
            #expect(stored?.token == "synthetic-key",
                    "the cloud task scanner saw no credentials while the gauge worked")
        }
    }

    @Test("A ChatGPT login is read from the nested tokens object")
    func chatGPTLogin() {
        withCodexHome(#"{"tokens":{"access_token":"synthetic","account_id":"acc-1"}}"#) {
            #expect(CodexProvider().isConfigured)
            #expect(CodexProvider.storedAuth()?.token == "synthetic")
            #expect(CodexProvider.storedAuth()?.accountID == "acc-1")
        }
    }

    /// The file existing is not the same as being signed in. It used to be:
    /// an empty auth.json earned a menu bar item that could never report
    /// anything, which is the outcome first-run detection exists to avoid.
    @Test("An auth file with no token in it is not a sign-in", arguments: [
        "{}", #"{"tokens":{}}"#, #"{"access_token":""}"#, "not json at all",
    ])
    func emptyAuthIsNotSignedIn(_ contents: String) {
        withCodexHome(contents) {
            #expect(CodexProvider().isConfigured == false)
            #expect(CodexProvider.storedAuth() == nil)
        }
    }

    @Test("No auth file at all is not a sign-in")
    func missingAuthIsNotSignedIn() {
        withCodexHome(nil) {
            #expect(CodexProvider().isConfigured == false)
            #expect(CodexProvider.storedAuth() == nil)
        }
    }
}

/// Two reads that were not bounded while everything around them was. Both
/// fail the same way if left alone: the app buffers whatever it is given.
@Suite("Credential reads are bounded like every other read here")
struct CredentialBoundsTests {

    @Test("An oversized credentials file is refused rather than buffered")
    func oversizedCredentialFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("credentials-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        // Valid JSON, and far past anything a credential could be.
        let padding = String(repeating: "x", count: 512 * 1_024)
        try Data(#"{"claudeAiOauth":{"accessToken":"\#(padding)"}}"#.utf8).write(to: file)
        #expect(ClaudeCredentials.fromFile(file) == nil,
                "a half-megabyte credential was read in full")
    }

    @Test("A credentials file of ordinary size is still read")
    func ordinaryCredentialFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("credentials-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"claudeAiOauth":{"accessToken":"synthetic-token"}}"#.utf8).write(to: file)
        #expect(ClaudeCredentials.fromFile(file) != nil,
                "the bound must not refuse a real credential")
    }

    /// A credential command's output becomes a bearer token. Truncated output
    /// is not a short token, it is a different string — and one that would be
    /// sent to the endpoint as though it were real.
    @Test("A credential command that floods its output yields no token")
    func floodingCredentialCommand() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func provider(printing count: Int) throws -> DescriptorProvider {
            let script = dir.appendingPathComponent("emit-\(count)")
            try Data("#!/bin/sh\nprintf 'x%.0s' $(seq 1 \(count))\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
            let object: [String: Any] = [
                "formatVersion": 1, "id": "flood-\(UUID().uuidString)", "name": "Flood",
                "process": [:], "source": ["kind": "none", "path": ""],
                "quota": ["endpoint": "https://example.invalid/u",
                          "credential": ["kind": "command", "command": script.path],
                          "windows": ["list": "d", "usedPercent": "p"]]]
            let descriptor = try HarnessDocument.decode(
                JSONSerialization.data(withJSONObject: object)).descriptor
            return try #require(DescriptorProvider(descriptor))
        }

        // Well past the cap: the output cannot be a token.
        let flooded = try provider(printing: 40_000).token()
        #expect(flooded == nil, "truncated output was accepted as a token")
        // And a normal one still is, so the cap is not refusing everything.
        let ordinary = try provider(printing: 64).token()
        #expect(ordinary == String(repeating: "x", count: 64))
    }
}
