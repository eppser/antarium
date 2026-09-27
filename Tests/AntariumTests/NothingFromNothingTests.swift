import Foundation
import Testing
@testable import Antarium

/// A reply this app cannot read produces no figure at all.
///
/// The strongest form of the rule the whole project rests on: missing, zero and
/// unreadable are different, and only the first two may ever reach a gauge. A
/// provider that turned an empty reply into a meter would draw a bar at nought on
/// an account nobody had asked about — indistinguishable from a quota with
/// everything left.
///
/// Every quota fixture already carries a case for a reply it cannot read, so this
/// is not a suspicion. It is the claim asked of *every* provider in one place and
/// in the emptiest shapes there are, so a provider added later is held to it
/// without anybody remembering to write the case.
@Suite("No provider makes a figure out of nothing")
struct NothingFromNothingTests {

    /// The shapes a reply can be empty in: nothing at all, an empty envelope, and
    /// an envelope whose contents are the wrong kind of nothing.
    private var emptyReplies: [(name: String, json: [String: Any])] {
        [
            ("an empty object", [:]),
            ("an empty envelope", ["data": [String: Any]()]),
            ("an envelope of null", ["data": NSNull()]),
            ("an empty list where an object belongs", ["data": [Any]()]),
        ]
    }

    /// Every provider described by a harness file.
    @Test("A descriptor provider reports nothing rather than a gauge")
    func descriptorProviders() throws {
        var examined = 0
        for descriptor in HarnessCLI.bundledDescriptors() {
            guard descriptor.quota != nil,
                  let provider = DescriptorProvider(descriptor) else { continue }
            examined += 1
            for reply in emptyReplies {
                let snapshot = try? provider.makeSnapshot(reply.json)
                #expect(snapshot == nil,
                        Comment(rawValue: "\(descriptor.id) built a snapshot from "
                                + "\(reply.name): \(snapshot?.gauges.count ?? 0) gauges"))
            }
        }
        #expect(examined == 11,
                Comment(rawValue: "\(examined) descriptor providers were examined"))
    }

    /// And the providers written in Swift, each through its own builder. Listed
    /// rather than reflected, because each takes different arguments — and the
    /// count below says the list is the whole of them.
    @Test("A native provider reports nothing rather than a gauge")
    func nativeProviders() throws {
        let token = ClaudeToken(accessToken: "synthetic", expiresAt: nil,
                                subscriptionType: nil, source: .file)
        var examined = 0
        for reply in emptyReplies {
            examined += 1
            #expect(throws: (any Error).self, Comment(rawValue: "claude-code: \(reply.name)")) {
                _ = try ClaudeCodeProvider.makeSnapshot(reply.json, token: token)
            }
            #expect(throws: (any Error).self, Comment(rawValue: "codex: \(reply.name)")) {
                _ = try CodexProvider.makeSnapshot(reply.json)
            }
            #expect(throws: (any Error).self, Comment(rawValue: "cursor: \(reply.name)")) {
                _ = try CursorProvider.makeSnapshot(reply.json, planName: nil)
            }
            #expect(throws: (any Error).self, Comment(rawValue: "cursor legacy: \(reply.name)")) {
                _ = try CursorProvider.makeSnapshotFromLegacy(reply.json, planName: nil)
            }
            #expect(throws: (any Error).self, Comment(rawValue: "gemini: \(reply.name)")) {
                _ = try GeminiProvider.makeSnapshot(reply.json)
            }
            #expect(throws: (any Error).self, Comment(rawValue: "grok: \(reply.name)")) {
                _ = try GrokProvider.makeSnapshot(reply.json)
            }
        }
        #expect(examined == emptyReplies.count)
    }

    /// The two that read text rather than JSON, held to the same rule.
    @Test("A provider reading text reports nothing for empty text", arguments: ["", "   ", "\n"])
    func textProviders(text: String) {
        #expect(throws: (any Error).self, Comment(rawValue: "amp: \(text.debugDescription)")) {
            _ = try AmpProvider.makeSnapshot(text)
        }
        #expect(throws: (any Error).self, Comment(rawValue: "kiro: \(text.debugDescription)")) {
            _ = try KiroProvider.makeSnapshot(text, now: Date())
        }
    }

    /// The list of native builders is the whole set, so a provider added later is
    /// not quietly outside this. Counted against what ships rather than against a
    /// number written here.
    @Test("Every native provider has a builder this suite covers")
    func everyNativeProviderIsCovered() {
        let covered = ["claude-code", "codex", "cursor", "gemini", "grok", "ampcode", "kiro"]
        let shipped = ProviderRegistry.nativeProviders.map(\.id).sorted()
        #expect(shipped == covered.sorted(),
                Comment(rawValue: "shipped: \(shipped); covered here: \(covered.sorted())"))
    }

    /// And the rule is not satisfied by refusing everything: a real reply still
    /// builds. One provider is enough to show the suite is not vacuous, and its
    /// own fixture covers the rest.
    @Test("A real reply still builds a snapshot")
    func realRepliesStillWork() throws {
        let descriptor = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "moonshot" })
        let provider = try #require(DescriptorProvider(descriptor))
        let reply = try #require(try JSONSerialization.jsonObject(
            with: Data(#"{"data":{"available_balance":12.5}}"#.utf8)) as? [String: Any])
        #expect(try provider.makeSnapshot(reply).gauges.count == 1)
    }
}
