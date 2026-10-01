import Foundation
import Testing
@testable import Antarium

/// The credential path for the provider most people have.
///
/// It was the least-covered file outside the views — 20 per cent — and it
/// decides whether any Claude figure appears at all. Nothing can test the
/// Keychain routes, and nothing should: they prompt, they depend on this
/// machine's grants, and reading a real credential is not a thing a test does.
/// What can be tested is every decision made about what was read, and none of
/// those were.
@Suite("What Claude Code's stored credential says")
struct ClaudeCredentialTests {

    /// A credential file in a temporary directory. Synthetic throughout: the
    /// token is a word, and the only real thing is the shape.
    private func file(_ json: String, _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".credentials.json")
        try Data(json.utf8).write(to: url)
        try body(url)
    }

    private func token(_ json: String) throws -> ClaudeToken? {
        var found: ClaudeToken?
        try file(json) { found = ClaudeCredentials.fromFile($0) }
        return found
    }

    /// The division by a thousand, which nothing checked. Claude Code writes
    /// `expiresAt` in milliseconds; read as seconds, every token would look
    /// like it expired in 1970 and the bar would say "sign in again" for ever.
    @Test("An expiry is read as milliseconds, not seconds")
    func expiryIsMilliseconds() throws {
        let seconds = 1_790_000_000.0
        let parsed = try #require(try token(#"""
        {"claudeAiOauth":{"accessToken":"synthetic","expiresAt":\#(seconds * 1000)}}
        """#))
        let expiry = try #require(parsed.expiresAt)
        #expect(abs(expiry.timeIntervalSince1970 - seconds) < 1,
                Comment(rawValue: "read as \(expiry.timeIntervalSince1970), expected \(seconds)"))
        // And the sanity check that makes the claim mean something: read as
        // seconds it would land in 1970 and be expired.
        #expect(!parsed.isExpired(at: Date(timeIntervalSince1970: seconds - 1)))
    }

    @Test("A credential with no expiry is read, and is not expired")
    func noExpiry() throws {
        let parsed = try #require(try token(#"{"claudeAiOauth":{"accessToken":"synthetic"}}"#))
        #expect(parsed.expiresAt == nil)
        #expect(!parsed.isExpired, "a token stating no expiry was treated as expired")
        #expect(!parsed.isExpired(at: .distantFuture),
                "absence of an expiry is not a date in the past")
    }

    @Test("The subscription type is carried through when stated")
    func subscriptionType() throws {
        #expect(try token(#"""
        {"claudeAiOauth":{"accessToken":"synthetic","subscriptionType":"max"}}
        """#)?.subscriptionType == "max")
        #expect(try token(#"{"claudeAiOauth":{"accessToken":"synthetic"}}"#)?
            .subscriptionType == nil)
    }

    @Test("A file that is not this credential reads as nothing", arguments: [
        #"{}"#,
        #"{"claudeAiOauth":{}}"#,
        #"{"claudeAiOauth":{"accessToken":""}}"#,
        #"{"accessToken":"synthetic"}"#,
        #"{"claudeAiOauth":{"accessToken":123}}"#,
        #"not json at all"#,
        #"[]"#,
    ])
    func notThisCredential(json: String) throws {
        #expect(try token(json) == nil, Comment(rawValue: "\(json) read as a credential"))
    }

    /// An expiry that is not a number is not an expiry, and must not make the
    /// token unreadable either — the token is still there.
    @Test("An unreadable expiry leaves a usable token with no expiry")
    func unreadableExpiry() throws {
        let parsed = try #require(try token(#"""
        {"claudeAiOauth":{"accessToken":"synthetic","expiresAt":"tomorrow"}}
        """#))
        #expect(parsed.accessToken == "synthetic")
        #expect(parsed.expiresAt == nil)
        #expect(!parsed.isExpired)
    }

    @Test("The source is recorded as the file it came from")
    func sourceIsRecorded() throws {
        #expect(try token(#"{"claudeAiOauth":{"accessToken":"synthetic"}}"#)?.source == .file)
    }

    @Test("A missing file is nothing, not a failure")
    func missingFile() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        #expect(ClaudeCredentials.fromFile(absent) == nil)
    }
}

/// The order the provider tries what it found.
///
/// The provider tries each token until one is accepted, so this is not a
/// correctness question — but every attempt it wastes is a request to Anthropic
/// expected to fail, and two lines of the same file disagreed about which those
/// were. `isExpired` reads a missing expiry as "not expired", which is right;
/// the sort read it as `.distantPast`, which tried a token of unknown expiry
/// after every token whose expiry had demonstrably passed.
@Suite("Credentials are tried in the order most likely to work")
struct ClaudeTokenOrderTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func token(_ name: String, expires: TimeInterval?,
                       source: ClaudeToken.Source = .file) -> ClaudeToken {
        ClaudeToken(accessToken: name,
                    expiresAt: expires.map { Date(timeIntervalSince1970: $0) },
                    subscriptionType: nil, source: source)
    }

    private func order(_ tokens: [ClaudeToken]) -> [String] {
        ClaudeCredentials.ordered(tokens, now: now).map(\.accessToken)
    }

    /// The finding, stated as the order it produced.
    @Test("A token of unknown expiry is tried before one that has expired")
    func unknownBeatsExpired() {
        let order = order([token("expired", expires: now.timeIntervalSince1970 - 60),
                           token("unknown", expires: nil)])
        #expect(order == ["unknown", "expired"],
                Comment(rawValue: "tried \(order), spending a request on the expired one first"))
    }

    /// A token stating a future expiry comes before one stating none. Claude
    /// Code wrote that date because it believes the token is good until then,
    /// and positive evidence of validity beats no evidence either way.
    @Test("A token stating a future expiry is tried before one stating none")
    func liveFirst() {
        let order = order([token("expired", expires: now.timeIntervalSince1970 - 60),
                           token("unknown", expires: nil),
                           token("live", expires: now.timeIntervalSince1970 + 3_600)])
        #expect(order == ["live", "unknown", "expired"],
                Comment(rawValue: "tried \(order)"))
    }

    @Test("Among live tokens the later expiry comes first")
    func laterExpiryFirst() {
        #expect(order([token("soon", expires: now.timeIntervalSince1970 + 60),
                       token("later", expires: now.timeIntervalSince1970 + 3_600)])
                == ["later", "soon"])
    }

    @Test("Among expired tokens the more recent expiry comes first")
    func recentlyExpiredFirst() {
        #expect(order([token("old", expires: now.timeIntervalSince1970 - 3_600),
                       token("recent", expires: now.timeIntervalSince1970 - 60)])
                == ["recent", "old"])
    }

    /// The same token from two stores is one token, and the first store wins —
    /// which is the cheapest one, since the sources are tried cheapest first.
    @Test("One token found twice is one token")
    func duplicatesCollapse() {
        let ordered = ClaudeCredentials.ordered(
            [token("same", expires: nil, source: .securityTool),
             token("same", expires: nil, source: .file)], now: now)
        #expect(ordered.count == 1)
        #expect(ordered.first?.source == .securityTool,
                "the later duplicate replaced the cheaper source it was found from")
    }

    /// A token expiring exactly now is expired. The boundary is worth stating:
    /// a request sent with it would arrive after it lapsed.
    @Test("A token expiring exactly now is expired")
    func expiringNow() {
        #expect(token("edge", expires: now.timeIntervalSince1970).isExpired(at: now))
        #expect(!token("edge", expires: now.timeIntervalSince1970 + 1).isExpired(at: now))
    }

    /// The order must not depend on the order it was given, or the bar would
    /// try a different token each scan for no reason. `sorted(by:)` is not
    /// stable, so equal tokens are separated by where they were found.
    @Test("Tokens that tie are ordered the same way every time")
    func tiesAreStable() {
        let tokens = (1...6).map { token("row-\($0)", expires: nil) }
        let wanted = order(tokens)
        for _ in 0..<25 {
            #expect(order(tokens) == wanted)
        }
        #expect(wanted == tokens.map(\.accessToken),
                "tokens that tie should keep the order their sources were tried in")
    }

    @Test("Nothing found is nothing ordered")
    func empty() {
        #expect(ClaudeCredentials.ordered([], now: now).isEmpty)
    }
}
