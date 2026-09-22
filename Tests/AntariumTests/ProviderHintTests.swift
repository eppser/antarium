import Foundation
import Testing
@testable import Antarium

/// What a failing agent tells the user to do about it.
///
/// `suggestsSignIn` states the rule plainly: a missing or rejected credential
/// is worth a login, and "a network failure or an unparseable response is not
/// the user's to fix, and offering a login for it would just waste their
/// time". The menu that shows the advice kept its own list of cases and put
/// `.unsupported` in with the credential ones — so a free Cursor account with
/// no plan, and a host that had moved its endpoint, were both told to sign in
/// to an account they were already signed in to.
@Suite("A failing agent gives advice that matches its failure")
struct ProviderHintTests {

    private let setup = "Sign in to Example in the desktop app."

    @Test("A credential problem asks for the credential",
          arguments: [ProviderError.needsAuth("t"), ProviderError.notConfigured("t")])
    func credentialProblemsOfferSetup(error: ProviderError) {
        #expect(error.hint(setupHint: setup) == setup)
        #expect(error.suggestsSignIn)
    }

    /// The case that was wrong. The service answered; it simply had nothing
    /// this app can chart, and signing in again cannot change that.
    @Test("An answer with nothing chartable in it does not ask for a login")
    func unsupportedDoesNotOfferSetup() {
        let error = ProviderError.unsupported("Cursor reported no plan usage.")
        let hint = error.hint(setupHint: setup)
        #expect(hint != setup, "a login was offered for something a login cannot fix")
        #expect(!error.suggestsSignIn)
        #expect(hint.contains("Signing in again will not change it"),
                Comment(rawValue: "the advice does not say why signing in is pointless: \(hint)"))
    }

    @Test("A transport failure says it will retry, and asks nothing of anybody")
    func transportRetries() {
        let hint = ProviderError.transport("timed out").hint(setupHint: setup)
        #expect(hint != setup)
        #expect(hint.contains("retry"))
    }

    @Test("An unreadable answer is not the user's to fix either")
    func badResponseIsNotTheirs() {
        let hint = ProviderError.badResponse("garbage").hint(setupHint: setup)
        #expect(hint != setup)
    }

    /// The keychain case is the one where the fix is neither a login nor
    /// nothing, and it names where to go.
    @Test("A refused keychain item says where to allow it")
    func accessDeniedNamesKeychain() {
        let hint = ProviderError.accessDenied("denied").hint(setupHint: setup)
        #expect(hint.contains("Keychain"))
        #expect(hint != setup)
    }

    /// Every case gives some advice: a blank hint under a red error line is
    /// worse than the wrong advice it replaced.
    @Test("Every failure says something",
          arguments: [ProviderError.needsAuth("t"), .notConfigured("t"), .accessDenied("t"),
                      .transport("t"), .badResponse("t"), .unsupported("t")])
    func everyCaseAdvises(error: ProviderError) {
        #expect(!error.hint(setupHint: setup).isEmpty,
                Comment(rawValue: "\(error) offers nothing"))
    }

    /// And the advice splits exactly where the rule says it does, so the two
    /// cannot drift apart again without this failing.
    @Test("Advice is the setup hint if and only if the rule says to sign in",
          arguments: [ProviderError.needsAuth("t"), .notConfigured("t"), .accessDenied("t"),
                      .transport("t"), .badResponse("t"), .unsupported("t")])
    func adviceFollowsTheRule(error: ProviderError) {
        #expect((error.hint(setupHint: setup) == setup) == error.suggestsSignIn,
                Comment(rawValue: "\(error) disagrees with suggestsSignIn"))
    }
}

/// The menu asks the rule rather than keeping its own list, which is how the
/// two came apart. A source rule, because the advice is assembled into an
/// NSMenuItem and nothing here can open a menu.
@Suite("The menu takes its advice from the error")
struct ProviderHintMenuContractTests {

    @Test("The problem item does not decide the advice for itself")
    func menuAsksTheError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/AgentItem.swift"), encoding: .utf8)
        let start = try #require(text.range(of: "private func problemItem("),
                                 "the problem item was renamed")
        let body = String(text[start.lowerBound...].prefix(900))
        #expect(body.contains("err.hint(setupHint:"),
                "the menu is choosing the advice again, where it can drift from the rule")
        #expect(!body.contains("case .needsAuth, .notConfigured, .unsupported"),
                "the list that put an unchartable answer in with the credential ones is back")
    }
}
