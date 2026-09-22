import Foundation
import Testing
@testable import Antarium

/// The first run's promise, across launches: the bar configures itself from
/// what is installed, and never argues with a choice the user has made.
///
/// Driven through the pure record functions rather than through settings on
/// disk. `Config` binds its path the first time it is touched, so pointing
/// `ANTARIUM_HOME` at a temporary directory mid-process does nothing — the
/// first attempt at this read the developer's own agents and passed.
///
/// `resolve` and `adoptions` were already covered on their own. What was not
/// is the bookkeeping that ties launches together: `known` is how a later
/// launch tells an agent that shipped since from one the user turned off, and
/// a run that chooses without recording it looks perfectly correct while
/// disabling adoption for ever.
@Suite("Across launches, the bar configures itself without overruling anyone")
struct FirstRunLifecycleTests {

    /// One install's settings as they would be on disk between launches.
    private struct Install {
        var enabled: Set<String>?
        var known: Set<String> = []

        mutating func launch(_ agents: [(id: String, signedIn: Bool, sessions: Bool)]) {
            let evidence = agents.map {
                AgentAutoEnable.Evidence(id: $0.id, signedIn: $0.signedIn,
                                         hasSessions: $0.sessions)
            }
            if let record = AgentAutoEnable.firstRunRecord(
                recorded: enabled.map { Array($0).sorted() },
                evidence: evidence, fallback: agents.map(\.id)) {
                enabled = record.enabled
                known = record.known
                return
            }
            let record = AgentAutoEnable.adoptionRecord(
                known: known, enabled: enabled ?? [],
                providers: agents.map { ($0.id, $0.signedIn) })
            enabled = (enabled ?? []).union(record.adopted)
            known = record.known
        }

        /// What the user does in Settings.
        mutating func userSwitchesOff(_ id: String) { enabled?.remove(id) }
    }

    private func agent(_ id: String, signedIn: Bool = true, sessions: Bool = false)
        -> (id: String, signedIn: Bool, sessions: Bool) { (id, signedIn, sessions) }

    /// The case the live machine cannot produce, and the one the whole
    /// sessions half of the evidence exists for: an agent used here but not
    /// signed in. Every provider this developer's Mac enables is also signed
    /// in, so a first run that threw the session set away behaved identically
    /// — which is exactly what it did, undetected, until the evidence step
    /// was moved out of `applyIfNeeded` and into a function a test can call.
    @Test("An agent used here but not signed in is still put in the bar")
    func sessionsAloneEarnASlot() throws {
        // The used agent is deliberately not first in the list. When nothing
        // at all is detected the fallback shows the first provider, so a test
        // that names the same agent in both places passes whether detection
        // worked or not — this one did, and the mutation that threw the
        // session set away survived it.
        let record = try #require(AgentAutoEnable.firstRunRecord(
            recorded: nil,
            providers: [("neither", false), ("used-not-signed-in", false)],
            sessions: ["used-not-signed-in"]))
        #expect(record.enabled == ["used-not-signed-in"],
                "the bar opened to \(record.enabled.sorted())")
        #expect(record.known == ["used-not-signed-in", "neither"],
                "an agent seen and passed over must still count as seen")
    }

    /// And the sessions it is handed are the ones it uses. Handing it a set
    /// naming an agent it was not told about must not conjure one.
    @Test("Sessions for an agent that is not a provider enable nothing")
    func sessionsForAnUnknownAgent() {
        let record = AgentAutoEnable.firstRunRecord(
            recorded: nil, providers: [("only-provider", false)],
            sessions: ["some-other-agent"])
        // No evidence at all, so the fallback shows one item rather than
        // leaving a menu bar with no way back into the app.
        #expect(record?.enabled == ["only-provider"])
    }

    @Test("A machine with no providers records nothing at all")
    func noProvidersRecordsNothing() {
        #expect(AgentAutoEnable.firstRunRecord(
            recorded: nil, providers: [], sessions: ["anything"]) == nil)
    }

    @Test("A first launch enables what is installed and records everything it saw")
    func firstLaunch() {
        var install = Install()
        install.launch([agent("a"), agent("b"), agent("c", signedIn: false)])
        #expect(install.enabled == ["a", "b"], "c showed no evidence at all")
        #expect(install.known == ["a", "b", "c"],
                "an agent seen and passed over must still count as seen")
    }

    @Test("A second launch changes nothing")
    func secondLaunchIsQuiet() {
        var install = Install()
        let agents = [agent("a"), agent("b")]
        install.launch(agents)
        install.launch(agents)
        #expect(install.enabled == ["a", "b"])
    }

    @Test("An agent that ships later and is signed in is adopted")
    func laterAgentAdopted() {
        var install = Install()
        install.launch([agent("a")])
        install.launch([agent("a"), agent("new")])
        #expect(install.enabled == ["a", "new"])
    }

    /// The other half of the ask. Automatic configuration must never undo a
    /// deliberate one: an agent the user switched off has been seen, so it is
    /// not new, however plainly it is installed.
    @Test("An agent the user switched off never comes back")
    func rejectionSticks() {
        var install = Install()
        install.launch([agent("a"), agent("b")])
        install.userSwitchesOff("b")
        install.launch([agent("a"), agent("b")])
        #expect(install.enabled == ["a"], "b switched itself back on")
    }

    @Test("An agent adopted and then switched off does not return either")
    func adoptedThenRejected() {
        var install = Install()
        install.launch([agent("a")])
        install.launch([agent("a"), agent("new")])
        install.userSwitchesOff("new")
        install.launch([agent("a"), agent("new")])
        #expect(install.enabled == ["a"])
    }

    @Test("An agent that ships later but is not signed in is left alone")
    func unsignedIsNotAdopted() {
        var install = Install()
        install.launch([agent("a")])
        install.launch([agent("a"), agent("new", signedIn: false, sessions: true)])
        #expect(install.enabled == ["a"], "that item could only say sign in")
    }

    @Test("Adoption cannot fill a bar the first run deliberately capped")
    func adoptionRespectsTheCap() {
        var install = Install()
        let full = (0..<AgentAutoEnable.limit).map { agent("a\($0)") }
        install.launch(full)
        #expect(install.enabled?.count == AgentAutoEnable.limit)
        install.launch(full + [agent("new")])
        #expect(install.enabled?.count == AgentAutoEnable.limit)
    }

    /// An install predating `knownAgents` cannot tell a new agent from a
    /// rejected one, so it records what it sees and adopts nothing.
    @Test("An upgrade with a choice but no record adopts nothing, then starts recording")
    func upgradeIsQuietOnce() {
        var install = Install(enabled: ["a"], known: [])
        install.launch([agent("a"), agent("b")])
        #expect(install.enabled == ["a"], "b was adopted before it could be told from a rejection")
        #expect(install.known == ["a", "b"])
        install.launch([agent("a"), agent("b")])
        #expect(install.enabled == ["a"], "and still not on the launch after")
    }

    @Test("A bar with nothing installed still gets one item, so there is a way back in")
    func emptyMachineIsNotAnEmptyBar() {
        var install = Install()
        install.launch([agent("a", signedIn: false), agent("b", signedIn: false)])
        #expect(install.enabled?.count == 1)
    }
}

/// The other half of the promise: the bar configures itself, and then the
/// user's choice wins. Detection has tests; what the Settings toggles
/// actually do had none, because the decision lived inside a SwiftUI body
/// where the only way to reach it was to click it.
@Suite("What the settings toggles do")
struct AgentToggleTests {

    @Test("Switching an agent on adds it and leaves the rest alone")
    func switchOn() {
        #expect(Settings.toggling("zai", on: true, in: ["codex", "cursor"])
            == .apply(["codex", "cursor", "zai"]))
    }

    @Test("Switching an agent off removes exactly that one")
    func switchOff() {
        #expect(Settings.toggling("cursor", on: false, in: ["codex", "cursor"])
            == .apply(["codex"]))
    }

    /// The rule that was enforced silently. `ProviderRegistry.shown` falls
    /// back to the first provider from an empty set, so the bar would not
    /// actually empty — but the user's click was discarded and the toggle
    /// sprang back, which reads as a broken control rather than a rule.
    @Test("Switching off the last agent is refused, with a reason")
    func lastOneIsRefused() throws {
        let outcome = Settings.toggling("codex", on: false, in: ["codex"])
        let why = try #require(outcome.refusal, "the last agent was switched off silently")
        #expect(why.contains("only agent"))
        #expect(outcome != .apply([]), "an empty choice was written")
    }

    /// Switching one off is fine as long as another remains, or the rule
    /// above would be a way of refusing every change.
    @Test("With two agents on, either can be switched off")
    func eitherOfTwo() {
        #expect(Settings.toggling("codex", on: false, in: ["codex", "zai"]).refusal == nil)
        #expect(Settings.toggling("zai", on: false, in: ["codex", "zai"]).refusal == nil)
    }

    /// Switching *on* is never refused, whatever the set looks like — the
    /// rule is about emptying the bar, not about changing it.
    @Test("Switching an agent on is never refused")
    func onIsNeverRefused() {
        #expect(Settings.toggling("codex", on: true, in: []).refusal == nil)
        #expect(Settings.toggling("codex", on: true, in: ["codex"])
            == .apply(["codex"]), "switching on an agent already on changed the set")
    }

    /// Switching off one that was never on is not a change and not a
    /// refusal — unless it would empty the bar, which it cannot.
    @Test("Switching off an agent that is not on leaves the set as it was")
    func offWhenNotOn() {
        #expect(Settings.toggling("zai", on: false, in: ["codex"]) == .apply(["codex"]))
    }
}

/// The first-run screen keeps the promise it makes.
///
/// It reports what was detected, and the session count is not ready when it
/// is drawn: the first scan is dispatched rather than awaited, so the screen
/// says "Counting sessions…" and used to say it for as long as the panel was
/// open. An ellipsis is a promise; nothing was keeping it.
///
/// A source rule, because the screen is an AppKit panel hosting a SwiftUI
/// view and nothing here can open one. It cannot show the count arrives —
/// only that the wiring which delivers it is still present, and that the
/// callback it borrows is handed back.
@Suite("The first-run screen is redrawn when the count arrives")
struct OnboardingCountContractTests {

    private func controller() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "Sources/Antarium/AppController.swift"), encoding: .utf8)
    }

    @Test("The panel is redrawn from the rows callback")
    func redrawsOnRows() throws {
        let text = try controller()
        let start = try #require(text.range(of: "func showOnboardingIfNeeded()"),
                                 "the first-run screen was renamed")
        let body = String(text[start.lowerBound...].prefix(2_600))
        #expect(body.contains("onRowsChanged"),
                "the screen is drawn once and never told the count")
        #expect(body.contains("rootView"),
                "nothing redraws the screen when the rows arrive")

        // The redraw's own resize, named apart from the one that happens when
        // the panel is built. Both call setContentSize, so looking for the
        // word anywhere would be satisfied by creation and say nothing about
        // the redraw — and the replacement line is longer than the
        // placeholder, so a panel still sized for the shorter one clips it.
        // A character window between the two was measured and rejected: they
        // sit close enough together that it would hold by luck.
        #expect(body.contains("onboardingPanel?.setContentSize"),
                "the panel is not resized for the line that arrives")
    }

    /// The callback belongs to the count item. Taking it and not giving it
    /// back would leave the menu bar's own count frozen for the session.
    @Test("The borrowed callback is called and handed back")
    func callbackIsRestored() throws {
        let text = try controller()
        let start = try #require(text.range(of: "func showOnboardingIfNeeded()"))
        let body = String(text[start.lowerBound...].prefix(2_600))
        #expect(body.contains("previousRowsChanged?(rows)"),
                "the count item stops updating while the first-run screen is open")
        #expect(body.contains("onRowsChanged = previousRowsChanged"),
                "the callback is never handed back")
    }
}

/// The case a real install reaches: an agent that was there at the first
/// launch and not signed in, signed into a week later.
///
/// Adoption is for agents the user has never been asked about — ones that
/// shipped after their choice. This one was on the list and showed no
/// evidence, so it was passed over, and passing over is a kind of answer.
/// Switching it on later is therefore the user's to do, and the settings
/// panel has to make that possible rather than leaving them to guess.
///
/// Both halves matter and only together: a rule that quietly declines to
/// add something is defensible when the thing is visible and one item away,
/// and indefensible when it is not.
@Suite("An agent signed into later is offered, not added")
struct SignedInLaterTests {

    private func agent(_ id: String, signedIn: Bool)
        -> (id: String, signedIn: Bool) { (id, signedIn) }

    @Test("Signing in later does not add it to the bar by itself")
    func notAdoptedOnSigningIn() {
        // A first run saw it, found nothing, and recorded having seen it.
        let seen: Set<String> = ["already-here", "chosen"]
        let adopted = AgentAutoEnable.adoptions(
            known: seen, enabled: ["chosen"],
            providers: [agent("chosen", signedIn: true),
                        agent("already-here", signedIn: true)])
        #expect(adopted.isEmpty,
                Comment(rawValue: "\(adopted.sorted()) was added to the bar without being asked"))
    }

    /// The distinction that makes the rule coherent: one the user has never
    /// been shown is adopted, one they were shown is not.
    @Test("An agent that was never on the list is still adopted")
    func newAgentIsStillAdopted() {
        let adopted = AgentAutoEnable.adoptions(
            known: ["chosen"], enabled: ["chosen"],
            providers: [agent("chosen", signedIn: true), agent("brand-new", signedIn: true)])
        #expect(adopted == ["brand-new"])
    }

    /// And the settings panel offers it, which is what the rule rests on.
    @Test("The settings list shows it as found here, waiting to be switched on")
    func settingsOffersIt() {
        let providers = ProviderRegistry.all
        let id = providers.first?.id ?? "claude-code"
        let rows = SettingsView.agentRows(
            providers: providers, enabled: [],
            evidence: [AgentAutoEnable.Evidence(id: id, signedIn: true, hasSessions: false)])
        let row = rows.first { $0.id == id }
        #expect(row?.present == true, "an agent signed in on this Mac is not marked as found")
        #expect(row?.enabled == false)
        #expect(row?.detail.contains("Signed in") == true,
                Comment(rawValue: "the row does not say why it is offered: " + (row?.detail ?? "")))
        #expect(SettingsView.agentCountSummary(rows).contains("more found here"),
                "the panel does not say that something was found and not shown")
    }
}
