import Foundation
import Testing
@testable import Antarium

/// Where each native provider sends the credential it read.
///
/// A descriptor states its credential file and its endpoint in one file and both
/// are corroborated — the file names the descriptor that reads it or carries a
/// `requires` clause, and the endpoint's domain is named again by the vendor
/// reference or the note. A native provider states the same two facts as Swift
/// literals forty lines apart with nothing comparing them, and a token read from
/// one vendor's file and posted to another vendor's host fails authentication:
/// the only symptom is a row saying "not signed in", which is what it says before
/// the user signs in at all.
///
/// So the pairs are written in `docs/TECHNICAL.md` and this holds the sources to
/// that table. Three of the five send a key to a domain carrying no trace of the
/// agent's name — Anthropic for Claude Code, ChatGPT for Codex, Google's Cloud
/// Code endpoint for Gemini — so the provider id cannot stand in for it, and
/// those are the rows where a wrong host would look most reasonable.
@Suite("A native provider's key goes where the reference says")
struct NativeEndpointTests {

    /// Provider file, the host it posts to, and a fragment of the credential it
    /// reads. Named individually rather than counted: a provider dropped from
    /// this list is a failure below, not a shorter loop.
    private static let pairs: [(file: String, host: String, credential: String)] = [
        ("ClaudeCodeProvider.swift", "api.anthropic.com", ".claude/.credentials.json"),
        ("CodexProvider.swift", "chatgpt.com", ".codex"),
        ("CursorProvider.swift", "api2.cursor.sh",
         "Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
        ("GeminiProvider.swift", "cloudcode-pa.googleapis.com", "oauth_creds.json"),
        ("GrokProvider.swift", "cli-chat-proxy.grok.com", "auth.json"),
    ]

    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Antarium/Providers")
    }

    private static func reference() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/TECHNICAL.md"), encoding: .utf8)
    }

    @Test("Each native provider posts to the host the reference names",
          arguments: pairs.map(\.file))
    func hostMatchesTheReference(file: String) throws {
        let pair = try #require(Self.pairs.first { $0.file == file })
        let text = try String(contentsOf: Self.sources.appendingPathComponent(file),
                              encoding: .utf8)
        // The line that builds the URL, not a comment mentioning it: a comment
        // saying the right thing beside code doing the wrong thing is the shape
        // this suite exists to refuse.
        let urls = text.split(separator: "\n")
            .filter { $0.contains("https://") && !$0.trimmingCharacters(in: .whitespaces)
                        .hasPrefix("//") }
        #expect(!urls.isEmpty, Comment(rawValue: "\(file) builds no URL"))
        for line in urls {
            #expect(line.contains(pair.host),
                    Comment(rawValue: "\(file) posts to \(line.trimmingCharacters(in: .whitespaces))"
                            + " and the reference says \(pair.host)"))
        }
        #expect(try Self.reference().contains(pair.host),
                Comment(rawValue: "docs/TECHNICAL.md no longer names \(pair.host), so nothing "
                        + "outside \(file) says where its key goes"))
    }

    @Test("Each native provider reads the credential the reference names",
          arguments: pairs.map(\.file))
    func credentialMatchesTheReference(file: String) throws {
        let pair = try #require(Self.pairs.first { $0.file == file })
        // Claude's path lives in ClaudeCredentials, which is where the Keychain
        // and the file are chosen between; the rest read their own.
        let owner = file == "ClaudeCodeProvider.swift" ? "ClaudeCredentials.swift" : file
        let text = try String(contentsOf: Self.sources.appendingPathComponent(owner),
                              encoding: .utf8)
        // On a line of code, not in a comment. The first version of this asked
        // whether the file mentioned the path anywhere, and every one of these
        // providers documents its own credential in prose a few lines above the
        // code that opens it — so changing Gemini's file from `oauth_creds.json`
        // to `auth.json` left the test green.
        let reads = text.split(separator: "\n").contains { line in
            line.contains(pair.credential)
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        #expect(reads, Comment(rawValue: "\(owner) no longer reads \(pair.credential) in any "
                               + "line of code — only, perhaps, in a comment"))
        #expect(try Self.reference().contains(pair.credential),
                Comment(rawValue: "docs/TECHNICAL.md no longer names \(pair.credential)"))
    }

    /// And the table is about every native provider that has an endpoint, so a
    /// sixth added later cannot be quietly absent from it.
    @Test("Every native provider with an endpoint is in the table")
    func tableIsComplete() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources,
                                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var withEndpoints: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            // DescriptorProvider's endpoint comes from the descriptor, so it
            // names none of its own; example.invalid is a test stand-in.
            guard url.lastPathComponent != "DescriptorProvider.swift" else { continue }
            let builds = text.split(separator: "\n").contains { line in
                line.contains("https://") && !line.contains("example")
                    && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            if builds { withEndpoints.append(url.lastPathComponent) }
        }
        let listed = Set(Self.pairs.map(\.file))
        let missing = withEndpoints.filter { !listed.contains($0) }.sorted()
        #expect(missing.isEmpty,
                Comment(rawValue: "\(missing.joined(separator: ", ")) posts to a host that "
                        + "docs/TECHNICAL.md does not account for"))
        #expect(withEndpoints.count >= 5,
                Comment(rawValue: "only \(withEndpoints.count) native providers build a URL"))
    }
}
