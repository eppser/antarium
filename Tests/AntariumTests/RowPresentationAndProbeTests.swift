import Foundation
import Testing
@testable import Antarium

/// What a harness row says about itself in the settings list.
///
/// Its own header says the spoken value is kept out of the view structure so
/// that icons and layout cannot silently remove essential compatibility
/// information. Nothing checked that it was there.
@Suite("What a harness row says")
struct HarnessRowPresentationTests {

    private func descriptor(_ object: [String: Any]) throws -> HarnessDescriptor {
        var full: [String: Any] = [
            "formatVersion": 1, "id": "row-\(UUID().uuidString)", "name": "Row",
            "process": [:], "source": ["kind": "none", "path": ""]]
        full.merge(object) { _, new in new }
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: full)).descriptor
    }

    private var quota: [String: Any] {
        ["endpoint": "https://example.invalid/u",
         "windows": ["list": "data", "usedPercent": "pct"]]
    }

    /// "Quota only" means it reads no sessions. A harness that reads sessions
    /// *and* charts a quota — opencode is one — reads sessions, and saying
    /// otherwise tells the user its transcript reader does not exist.
    @Test("A harness with both a source and a quota is not quota only")
    func bothIsNotQuotaOnly() throws {
        let row = HarnessRowPresentation(
            descriptor: try descriptor(["source": ["kind": "jsonl", "path": "~/x", "glob": "*.jsonl"],
                                        "quota": quota]),
            edited: false)
        #expect(row.sourceLabel == "JSON Lines",
                "a harness that reads sessions was labelled as reading none")
    }

    @Test("A harness with a quota and no source is quota only")
    func quotaWithNoSourceIsQuotaOnly() throws {
        let row = HarnessRowPresentation(descriptor: try descriptor(["quota": quota]),
                                         edited: false)
        #expect(row.sourceLabel == "Quota only")
    }

    /// A quota harness with no fixture beside it has not been verified
    /// against anything. Claiming otherwise is the one thing a compatibility
    /// label must never do.
    /// Three answers, not two. A descriptor with no fixture beside it has
    /// not been checked against anything — saying its mapping *failed*
    /// claims it was tried and broke, and sends whoever wrote it to look at
    /// the wrong thing.
    @Test("A quota harness with no fixture says only that it is declared")
    func noFixtureIsOnlyDeclared() throws {
        let row = HarnessRowPresentation(descriptor: try descriptor(["quota": quota]),
                                         edited: false)
        #expect(row.compatibilityLabel == "Declared",
                "a mapping nobody wrote a fixture for was reported as broken")
    }

    /// And a shipped one, which does have a fixture, reports the check that
    /// actually ran — so "Declared" cannot be reached by refusing to look.
    @Test("A shipped quota harness reports its verified fixture")
    func shippedQuotaHarnessIsVerified() throws {
        let url = try #require(AppResources.bundle.url(
            forResource: "openrouter", withExtension: "json", subdirectory: "harnesses"))
        let shipped = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
        let row = HarnessRowPresentation(descriptor: shipped, edited: false)
        #expect(row.compatibilityLabel == "Quota fixture verified")
    }

    /// The third answer. A descriptor whose id matches a shipped fixture but
    /// whose window map points at fields that payload does not have is a
    /// mapping that was checked and did not hold — which is a different
    /// thing from one nobody has checked, and has to read differently.
    @Test("A quota mapping that fails its fixture says so")
    func failedMappingSaysSo() throws {
        let row = HarnessRowPresentation(
            descriptor: try descriptor([
                "id": "openrouter",
                "quota": ["endpoint": "https://example.invalid/u",
                          "windows": ["single": "credits",
                                      "used": "nothing.here",
                                      "limit": "nothing.there"]]]),
            edited: false)
        #expect(row.compatibilityLabel == "Quota mapping failed",
                "a mapping that does not hold against its own fixture read as verified")
    }

    /// The reason this type exists, from its own header.
    @Test("The spoken label carries everything the row shows")
    func spokenLabelIsComplete() throws {
        let row = HarnessRowPresentation(descriptor: try descriptor(["quota": quota]),
                                         edited: true)
        #expect(row.accessibilityLabel.contains(row.name))
        #expect(row.accessibilityLabel.contains(row.sourceLabel))
        #expect(row.accessibilityLabel.contains(row.compatibilityLabel),
                "the spoken row dropped its compatibility")
        #expect(row.accessibilityLabel.contains("edited"))
    }

    @Test("A bundled harness is spoken as bundled")
    func bundledIsSpoken() throws {
        let row = HarnessRowPresentation(descriptor: try descriptor(["quota": quota]),
                                         edited: false)
        #expect(row.accessibilityLabel.contains("bundled"))
        #expect(!row.accessibilityLabel.contains("edited"))
    }

    /// The two places a user can *see* that a descriptor is their own edit:
    /// the badge beside the row, and the count above the list. Both were
    /// unasserted — mutating the provenance expression in this type was caught
    /// only by the spoken label, which is the right test for the spoken label
    /// and says nothing about what is on screen.
    @Test("The summary above the list counts the edited ones")
    func summaryCountsEdits() {
        #expect(HarnessRowPresentation.listSummary(total: 26, edited: 2)
                == "26 agents · 2 edited")
    }

    /// And says nothing when there is nothing to say: a line reading
    /// "0 edited" is a sentence about an absence.
    @Test("The summary is silent when nothing is edited")
    func summaryIsSilentWithoutEdits() {
        #expect(HarnessRowPresentation.listSummary(total: 26, edited: 0) == "26 agents")
        #expect(!HarnessRowPresentation.listSummary(total: 26, edited: 0).contains("edited"))
    }

    /// One edit is still singular in the count and plural in the noun, which
    /// is what the line says; asserted so that "1 edited" cannot quietly
    /// become "1 edits" or disappear below a threshold.
    @Test("A single edit is still counted")
    func summaryCountsOneEdit() {
        #expect(HarnessRowPresentation.listSummary(total: 26, edited: 1)
                == "26 agents · 1 edited")
    }

    /// And the line is wired to the two numbers it names. `listSummary` is
    /// pure and tested above, which says nothing about whether the view hands
    /// it the count of edited descriptors or something else.
    @Test("The summary is given the agent count and the edit count")
    func summaryIsWiredToTheCounts() throws {
        let source = try SourceText.read("Sources/Antarium/UI/SettingsView.swift")
        #expect(source.contains("HarnessRowPresentation.listSummary(total: all.count, "
                                + "edited: edited)"),
                "the summary line is no longer given the agent count and the edit count")
        #expect(source.contains("HarnessDescriptor.isEdited($0.id) }.count"),
                "the edit count is no longer counted from the descriptors")
    }

    /// The badge is the visible half, and it marks only the exception — a row
    /// saying "unchanged" on every line teaches nothing. Asserted on the
    /// source, because the condition is view structure rather than a value
    /// this type returns.
    @Test("The edited badge is shown only for an edited harness")
    func badgeIsConditional() throws {
        let source = try SourceText.read("Sources/Antarium/UI/SettingsView.swift")
        let row = try SourceText.chain("if isEdited {", in: source)
        #expect(row.contains("Text(\"edited\")"),
                "the badge is no longer what `if isEdited` guards")
    }

    /// A descriptor may name its own source label — the generic kind is a
    /// fallback, not an override.
    @Test("A declared source label wins over the generic one")
    func declaredLabelWins() throws {
        let row = HarnessRowPresentation(
            descriptor: try descriptor(["source": ["kind": "jsonl", "path": "~/x", "glob": "*.jsonl"],
                                        "presentation": ["sourceLabel": "Its own words"]]),
            edited: false)
        #expect(row.sourceLabel == "Its own words")
    }
}

/// The memo behind every `isConfigured`.
///
/// It exists because two of the native answers are not cheap — Claude's falls
/// through to a subprocess, Cursor's opens a database — and both are read
/// from inside a SwiftUI body. A memo that never expires means a sign-in
/// performed in a terminal never shows; one that never memoises puts a
/// subprocess in a view update, which is the hazard it was written for.
@Suite("Memoising whether an agent is signed in", .serialized)
struct ConfiguredProbeTests {

    private func key() -> String { "probe-\(UUID().uuidString)" }

    @Test("The answer is computed once inside the window")
    func computedOnceInsideTheWindow() {
        let id = key()
        var calls = 0
        for offset in [0.0, 1.0, 29.0] {
            _ = ConfiguredProbe.value(id, now: offset) { calls += 1; return true }
        }
        #expect(calls == 1, "the probe ran \(calls) times inside one window")
    }

    /// And recomputed after it, so a sign-in done in a terminal shows up
    /// while the user is still looking at the window.
    @Test("The answer is recomputed once the window passes")
    func recomputedAfterTheWindow() {
        let id = key()
        var calls = 0
        _ = ConfiguredProbe.value(id, now: 0) { calls += 1; return false }
        let after = ConfiguredProbe.value(id, now: ConfiguredProbe.ttl + 1) {
            calls += 1; return true
        }
        #expect(calls == 2)
        #expect(after)
    }

    /// The window is short enough to be worth having and long enough to stop
    /// a burst of view updates costing a subprocess each.
    @Test("The window is thirty seconds")
    func windowIsThirtySeconds() {
        #expect(ConfiguredProbe.ttl == 30)
    }

    /// `systemUptime` does not go backwards, but a cached entry from a
    /// previous process can outlive a sleep. An entry stamped in the future
    /// is not a fresh entry.
    @Test("An entry stamped in the future is recomputed, not trusted")
    func futureEntryIsRecomputed() {
        let id = key()
        var calls = 0
        _ = ConfiguredProbe.value(id, now: 1_000) { calls += 1; return true }
        _ = ConfiguredProbe.value(id, now: 10) { calls += 1; return false }
        #expect(calls == 2, "an entry from the future was treated as current")
    }

    /// Forgetting one agent must not forget the rest: signing into one is not
    /// a reason to run every other provider's probe again.
    @Test("Invalidating one key leaves the others")
    func invalidatingOneKey() {
        let first = key(), second = key()
        var firstCalls = 0, secondCalls = 0
        _ = ConfiguredProbe.value(first, now: 0) { firstCalls += 1; return true }
        _ = ConfiguredProbe.value(second, now: 0) { secondCalls += 1; return true }

        ConfiguredProbe.invalidate(first)
        _ = ConfiguredProbe.value(first, now: 1) { firstCalls += 1; return true }
        _ = ConfiguredProbe.value(second, now: 1) { secondCalls += 1; return true }

        #expect(firstCalls == 2, "the invalidated key was not recomputed")
        #expect(secondCalls == 1, "invalidating one key forgot another")
    }

    @Test("Invalidating everything forgets everything")
    func invalidatingEverything() {
        let id = key()
        var calls = 0
        _ = ConfiguredProbe.value(id, now: 0) { calls += 1; return true }
        ConfiguredProbe.invalidate()
        _ = ConfiguredProbe.value(id, now: 1) { calls += 1; return true }
        #expect(calls == 2)
    }

    @Test("The value that was computed is the value that comes back")
    func valueIsReturned() {
        let id = key()
        #expect(ConfiguredProbe.value(id, now: 0) { false } == false)
        #expect(ConfiguredProbe.value(id, now: 1) { true } == false,
                "the memo returned the new closure's answer instead of the cached one")
    }
}
