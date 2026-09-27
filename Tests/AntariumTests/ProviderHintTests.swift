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

/// The word in the menu bar when there is no reading at all.
///
/// The advice beside these failures is thoroughly checked above, and the advice
/// is the part a user has to hover or open the panel to read. The badge is the
/// part they see without doing anything: `AgentItem` renders it as the item's
/// whole message when a provider failed and there is no earlier reading to fall
/// back on. Nothing asserted it.
///
/// What that risks is the same rule the hints are held to, one surface earlier.
/// Two cases sharing a word make two different problems look like one, and a user
/// reads the bar and goes to the wrong fix — or to none, because "error" tells
/// them nothing about whether it is theirs to solve. The failure is silent in the
/// way this project keeps finding: every word is plausible, and the wrong one is
/// plausible too.
@Suite("The menu bar's word for a failure says which failure it is")
struct FailureBadgeTests {

    /// Every case, named with the word it shows. Named rather than derived: the
    /// point is that each one is the word intended for it, and a derived list
    /// would compare the implementation with itself.
    static let expected: [(ProviderError, String)] = [
        (.notConfigured("m"), "set up"),
        (.needsAuth("m"), "sign in"),
        (.accessDenied("m"), "keychain"),
        (.transport("m"), "offline"),
        (.badResponse("m"), "error"),
        (.unsupported("m"), "n/a"),
    ]

    @Test("Each failure shows the word written for it")
    func eachCaseHasItsWord() {
        for (error, word) in Self.expected {
            #expect(error.badge == word,
                    Comment(rawValue: "\(error) shows \"\(error.badge)\" where the bar should "
                            + "say \"\(word)\""))
        }
    }

    /// And no two share one, or the bar tells a user two problems are the same
    /// problem.
    @Test("No two failures share a word")
    func wordsAreDistinct() {
        let words = Self.expected.map { $0.0.badge }
        #expect(Set(words).count == words.count,
                Comment(rawValue: "these failures share a word: \(words)"))
    }

    /// The badge and the advice agree about whose problem it is. A bar reading
    /// "sign in" beside advice saying signing in will not help is the drift
    /// `hint(setupHint:)` records having had in the other direction, and this is
    /// the surface it would show on first.
    @Test("Only a failure signing in can fix says so in the bar")
    func onlySignInCasesSaySignIn() {
        for (error, _) in Self.expected {
            let invites = error.badge == "sign in" || error.badge == "set up"
            #expect(invites == error.suggestsSignIn,
                    Comment(rawValue: "the bar says \"\(error.badge)\" for a failure that "
                            + "\(error.suggestsSignIn ? "does" : "does not") suggest signing in"))
        }
    }

    /// Short enough to be a menu bar item on its own. These are rendered as the
    /// item's whole message, so a long one is what the user sees instead of a
    /// figure — and the longest here is eight characters.
    @Test("Every word fits a menu bar item")
    func wordsAreShort() {
        for (error, _) in Self.expected {
            #expect(error.badge.count <= 10,
                    Comment(rawValue: "\"\(error.badge)\" is \(error.badge.count) characters "
                            + "for a menu bar item"))
            #expect(!error.badge.isEmpty, "a failure shows nothing at all")
        }
    }

    /// And it is the badge the item renders, not the message the error carries —
    /// which is a developer's sentence and sometimes a server's.
    @Test("The bar shows the word, not the underlying message")
    func itemRendersTheBadge() throws {
        let source = try SourceText.read("Sources/Antarium/AgentItem.swift")
        #expect(source.contains("message: err.badge"),
                "the item no longer renders the badge, so the bar may be showing a raw message")
    }
}

/// A figure that is no longer current says so in words, not only in grey.
///
/// When a refresh fails and an earlier reading exists, the menu shows that
/// reading rather than an error — the right choice, and the reason the badge
/// tests above only cover the case where there is nothing to fall back on.
///
/// It was marked by dimming the gauge's title and by nothing else. `attributedTitle`
/// is what a screen reader reads and colour is not in it, so a listener heard an
/// old figure as the current one, and a user who does not notice a shade of grey
/// saw one. The tooltip and the dashboard both said "as of" already; the menu,
/// which is the surface a user opens, did not.
///
/// This is the argument this project already made for speaking "Estimated"
/// instead of only showing it: a reader who hears the row has no tooltip to fall
/// back on, so a bare figure is where an estimate reads as a measurement. An old
/// figure reads as a current one in the same place.
@Suite("An old reading in the menu says it is old")
struct StaleGaugeDetailTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func gauge() -> Gauge {
        Gauge(id: "w", badge: "5H", title: "Session", used: 0.4,
              resetsAt: Date(timeIntervalSince1970: 1_800_010_000))
    }

    @Test("A current reading says nothing about when it was taken")
    func freshSaysNothing() {
        let text = AgentItem.gaugeDetail(gauge(), asOf: nil, now: now)
        #expect(!text.contains("as of"),
                Comment(rawValue: "a fresh reading dated itself: \(text)"))
        // And still carries both framings, which is the line's whole job.
        #expect(text.contains("used") && text.contains("left"),
                Comment(rawValue: "the detail lost a framing: \(text)"))
    }

    @Test("An old reading says when it was taken")
    func staleSaysWhen() {
        let taken = now.addingTimeInterval(-42 * 60)
        let text = AgentItem.gaugeDetail(gauge(), asOf: taken, now: now)
        #expect(text.contains("as of 42 min ago"),
                Comment(rawValue: "an old reading did not date itself: \(text)"))
        // The figure is still there: dating it is an addition, not a replacement.
        #expect(text.contains("used"), Comment(rawValue: "the figure went: \(text)"))
    }

    /// The two differ, which is the whole point and the thing colour alone could
    /// not carry.
    @Test("The two read differently")
    func theyDiffer() {
        #expect(AgentItem.gaugeDetail(gauge(), asOf: nil, now: now)
                != AgentItem.gaugeDetail(gauge(), asOf: now.addingTimeInterval(-600), now: now))
    }

    /// A balance has no percentage, and the dating has to reach it too — that
    /// branch builds its own string and would be the easy one to miss.
    @Test("A balance is dated as well as a meter")
    func balanceIsDated() {
        let balance = Gauge(id: "b", badge: "BAL", title: "Credits", used: 0,
                            amount: Gauge.Amount(value: 12.5, currency: "USD"))
        let text = AgentItem.gaugeDetail(balance, asOf: now.addingTimeInterval(-600), now: now)
        #expect(text.contains("as of"), Comment(rawValue: "a balance was not dated: \(text)"))
        #expect(text.contains("left"), Comment(rawValue: "a balance lost its figure: \(text)"))
    }

    /// And the item asks for the date rather than deciding it, or the four cases
    /// above are about something the menu does not show.
    @Test("The menu item builds its detail from the callable one")
    func itemUsesIt() throws {
        let source = try SourceText.read("Sources/Antarium/AgentItem.swift")
        #expect(source.contains("let detail = Self.gaugeDetail(g, asOf: asOf)"),
                "the menu item no longer builds its detail from the function these test")
        #expect(source.contains("let asOf: Date? = stale ? s.fetchedAt : nil"),
                "the menu no longer passes the time an old reading was taken")
    }
}
