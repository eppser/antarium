import Foundation
import Testing
@testable import Antarium

/// A service that rejects a credential with an HTTP 200.
///
/// `UsageHTTP` turns 401 and 403 into `needsAuth`, which offers the user a
/// sign-in. Two shipped endpoints never send one. Probed on 2026-09-27 with a
/// deliberately invalid token and no account data: MiniMax answers 200 with
/// `base_resp.status_code` 1004 and the message "cookie is missing, log in
/// again"; Z.ai answers 200 with `code` 401 and "token expired or incorrect".
///
/// No figure was ever in danger — neither body carries a window, so the mapping
/// found none and reported `unsupported`. What the user was told was wrong:
/// "reported no usage window" points at this app rather than at their expired
/// token, and `unsupported` offers no sign-in where `needsAuth` does. A fixture
/// could not have found this: it replays a recorded *successful* body.
@Suite("A rejected credential is a rejected credential whatever the status was")
struct AuthInBodyTests {

    private func attempt(_ id: String, _ json: String) throws -> ProviderError? {
        let descriptor = try #require(HarnessCLI.bundledDescriptors().first { $0.id == id })
        let provider = try #require(DescriptorProvider(descriptor))
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                     as? [String: Any])
        do { _ = try provider.makeSnapshot(reply); return nil }
        catch let error as ProviderError { return error }
    }

    /// The body Z.ai actually sent.
    @Test("Z.ai's rejected-token reply asks the user to sign in")
    func zai() throws {
        let error = try #require(try attempt("zai",
            #"{"code":401,"msg":"token expired or incorrect","success":false}"#))
        guard case .needsAuth = error else {
            Issue.record(Comment(rawValue: "got \(error), which offers no sign-in"))
            return
        }
        #expect(error.suggestsSignIn, "the menu would not offer to sign the user in")
    }

    /// And the body MiniMax actually sent, whose code is nested.
    @Test("MiniMax's missing-cookie reply asks the user to sign in")
    func minimax() throws {
        let error = try #require(try attempt("minimax",
            #"{"base_resp":{"status_code":1004,"status_msg":"cookie is missing, log in again"}}"#))
        guard case .needsAuth = error else {
            Issue.record(Comment(rawValue: "got \(error), which offers no sign-in"))
            return
        }
        #expect(error.suggestsSignIn)
    }

    /// The message names the provider and never echoes the service's own text. A
    /// remote string in a menu would need bounding, and there is nothing in it
    /// the user needs that this does not say.
    @Test("The message is this app's own words, not the service's")
    func messageIsOurs() throws {
        let error = try #require(try attempt("zai",
            #"{"code":401,"msg":"token expired or incorrect","success":false}"#))
        guard case .needsAuth(let text) = error else { return }
        #expect(text.contains("Z.ai"))
        #expect(!text.contains("token expired or incorrect"),
                "the service's own message was echoed into the app")
    }

    /// A different failure is not a sign-in problem. Z.ai's `success: false`
    /// covers every error it has, which is why the rule matches the code.
    @Test("Another failure code is not read as a rejected credential")
    func otherFailureIsNotAuth() throws {
        let error = try #require(try attempt("zai",
            #"{"code":500,"msg":"internal error","success":false}"#))
        if case .needsAuth = error {
            Issue.record("a server fault was reported as a sign-in problem")
        }
    }

    @Test("Another MiniMax code is not read as a rejected credential")
    func otherMiniMaxCodeIsNotAuth() throws {
        let error = try #require(try attempt("minimax",
            #"{"base_resp":{"status_code":1002,"status_msg":"rate limit"}}"#))
        if case .needsAuth = error {
            Issue.record("a rate limit was reported as a sign-in problem")
        }
    }

    /// A successful reply still maps, or the rule would be refusing everything.
    @Test("A real reply is unaffected")
    func realReplyStillMaps() throws {
        let descriptor = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "minimax" })
        let provider = try #require(DescriptorProvider(descriptor))
        let report = QuotaFixture.verify(descriptor, in: AppResources.bundle)
        #expect(report?.passed == true, Comment(rawValue: report?.detail ?? "no report"))
        _ = provider
    }

    /// The decision on its own, over the shapes a value can arrive in.
    @Test("The rule compares the value the reply carries")
    func ruleComparesValues() throws {
        let quota = try #require(HarnessCLI.bundledDescriptors()
            .first { $0.id == "zai" }?.quota)
        func says(_ json: String) throws -> Bool {
            let reply = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                         as? [String: Any])
            return DescriptorProvider.repliesUnauthenticated(quota, reply)
        }
        // A number, which is what the service sends.
        #expect(try says(#"{"code":401}"#))
        // And text, since a filter compares the same way everywhere.
        #expect(try says(#"{"code":"401"}"#))
        #expect(try !says(#"{"code":403}"#))
        #expect(try !says("{}"), "a reply stating nothing was read as a rejection")
        #expect(try !says(#"{"code":null}"#))
    }

    /// A descriptor declaring no rule says nothing, or every provider without one
    /// would start refusing its own replies.
    @Test("A provider with no rule is unaffected")
    func noRuleSaysNothing() throws {
        var checked = 0
        for descriptor in HarnessCLI.bundledDescriptors() {
            guard let quota = descriptor.quota, quota.needsAuthWhen == nil else { continue }
            checked += 1
            #expect(!DescriptorProvider.repliesUnauthenticated(quota, ["code": 401]),
                    Comment(rawValue: "\(descriptor.id) declares no rule and claimed a rejection"))
        }
        #expect(checked >= 8, Comment(rawValue: "only \(checked) providers were checked"))
    }

    /// Two pairs, which neither shipped rule has — so nothing distinguished a
    /// conjunction from "any of these" until this existed, and that mutation
    /// survived. A service that needs both to be sure is the case the rule is
    /// documented as handling.
    @Test("A rule of two pairs needs both")
    func everyPairMustHold() throws {
        let document = Data("""
        {
          "formatVersion":\(HarnessDocument.currentVersion),
          "id":"two-pair","name":"Two pair","process":{"pathContains":["/two-pair"]},
          "source":{"kind":"none","path":""},
          "quota":{"endpoint":"https://example.invalid/usage",
                   "needsAuthWhen":{"code":"401","scope":"auth"},
                   "windows":{"single":"b","balance":"balance","currency":"USD"}}
        }
        """.utf8)
        let quota = try #require(try HarnessDocument.decode(document).descriptor.quota)
        func says(_ json: String) throws -> Bool {
            let reply = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                         as? [String: Any])
            return DescriptorProvider.repliesUnauthenticated(quota, reply)
        }
        #expect(try says(#"{"code":401,"scope":"auth"}"#), "both held and it said nothing")
        #expect(try !says(#"{"code":401,"scope":"quota"}"#),
                "one pair of two was enough to claim a rejected credential")
        #expect(try !says(#"{"code":500,"scope":"auth"}"#),
                "the other pair alone was enough")
        #expect(try !says(#"{"code":401}"#), "a missing pair was treated as holding")
    }

    /// And the two that do declare one are the two that were probed.
    @Test("Only the endpoints that answer 200 declare the rule")
    func onlyTheProbedTwo() {
        let declaring = HarnessCLI.bundledDescriptors()
            .filter { $0.quota?.needsAuthWhen != nil }.map(\.id).sorted()
        #expect(declaring == ["minimax", "zai"],
                Comment(rawValue: "declaring needsAuthWhen: \(declaring)"))
    }
}
