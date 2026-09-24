import Foundation
import Testing
@testable import Antarium

/// The verifiers themselves. Every "fixture verified" claim in this project —
/// and the whole answer to "can this be tested without installing the agent"
/// — rests on these two functions, and nothing had shown either of them could
/// fail. A verifier that always says yes passes every test that asserts a
/// fixture passes.
@Suite("The fixture verifiers can fail", .serialized)
struct FixtureVerifierTests {

    /// A directory standing in for the resource bundle. Bundle resolves
    /// resources relative to a plain directory, which is all these need.
    private func bundle(fixture name: String, _ body: [String: Any]) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verifier-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("harness-fixtures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: body)
            .write(to: dir.appendingPathComponent("\(name).json"))
        return (try #require(Bundle(url: root)), root)
    }

    private func descriptor(fixture path: String?) throws -> HarnessDescriptor {
        var compatibility: [String: Any] = ["level": "declared", "note": "synthetic"]
        if let path { compatibility["fixture"] = path }
        let object: [String: Any] = [
            "formatVersion": 1, "id": "verifier-\(UUID().uuidString)", "name": "Fixture",
            "process": [:],
            "source": ["kind": "jsonl", "path": "", "glob": "*.jsonl"],
            "map": ["cwd": "cwd", "inputTokens": "input", "outputTokens": "output"],
            "compatibility": compatibility]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    private let record = #"{"cwd":"/synthetic","input":10,"output":5}"# + "\n"

    private func expected(inputTokens: Int) -> [String: Any] {
        // No `contextTokens`: this descriptor maps none, and declaring zero
        // would be the fixture asserting a figure nothing read — which is
        // what eight shipped fixtures were doing.
        ["sessions": 1, "cwd": "/synthetic", "inputTokens": inputTokens,
         "outputTokens": 5, "cacheRead": 0, "cacheWrite": 0,
         "toolCalls": 0, "turns": 0, "subAgents": 0, "costUSD": 0]
    }

    /// The positive control. Without it, everything below is satisfied by a
    /// verifier that rejects everything, which is the opposite bug and just
    /// as silent.
    @Test("A fixture whose numbers match is reported as verified")
    func matchingFixturePasses() throws {
        let (bundle, root) = try self.bundle(
            fixture: "good",
            ["files": ["trace.jsonl": record], "expected": expected(inputTokens: 10)])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = HarnessCompatibility.verifyFixture(
            try descriptor(fixture: "harness-fixtures/good.json"), in: bundle)
        #expect(report.status == .fixtureVerified, Comment(rawValue: report.detail))
    }

    /// The one that matters: a fixture declaring the wrong numbers must be
    /// refused. If this passes, every fixture in the project is decoration.
    @Test("A fixture whose numbers are wrong is refused")
    func wrongFixtureFails() throws {
        let (bundle, root) = try self.bundle(
            fixture: "wrong",
            ["files": ["trace.jsonl": record], "expected": expected(inputTokens: 999)])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = HarnessCompatibility.verifyFixture(
            try descriptor(fixture: "harness-fixtures/wrong.json"), in: bundle)
        #expect(report.status == .incompatible)
        #expect(report.expected != report.actual, "the difference must be reportable")
    }

    @Test("A declared fixture that is not there is refused, not assumed")
    func missingFixtureFails() throws {
        let (bundle, root) = try self.bundle(fixture: "unrelated", ["files": [:]])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = HarnessCompatibility.verifyFixture(
            try descriptor(fixture: "harness-fixtures/absent.json"), in: bundle)
        #expect(report.status == .incompatible)
    }

    @Test("A descriptor with no fixture is declared, never verified")
    func noFixtureIsNotVerified() throws {
        let (bundle, root) = try self.bundle(fixture: "unused", ["files": [:]])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = HarnessCompatibility.verifyFixture(try descriptor(fixture: nil), in: bundle)
        #expect(report.status != .fixtureVerified)
    }
}

/// The same question for the quota side. `--verify-harness-quota` reports
/// eight passing fixtures; that is worth nothing unless it can report a
/// failing one.
@Suite("The quota fixture verifier can fail", .serialized)
struct QuotaFixtureVerifierTests {

    private func bundle(_ cases: [[String: Any]]) throws -> (Bundle, URL, String) {
        let id = "quota-verifier-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qv-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("quota-fixtures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["cases": cases])
            .write(to: dir.appendingPathComponent("\(id).json"))
        return (try #require(Bundle(url: root)), root, id)
    }

    private func descriptor(_ id: String,
                            criticalWhen: [String: Bool]? = nil) throws -> HarnessDescriptor {
        var windows: [String: Any] = ["list": "data", "usedPercent": "pct"]
        if let criticalWhen { windows["criticalWhen"] = criticalWhen }
        let object: [String: Any] = [
            "formatVersion": 1, "id": id, "name": "Fixture", "process": [:],
            "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": "https://example.invalid/u", "windows": windows]]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    /// A fixture can now state that a provider reported a window spent, and
    /// a statement nothing checks is worse than none — it reads as coverage.
    @Test("A fixture claiming a spent window from a mapping that reports none is refused")
    func severityMismatchIsRefused() throws {
        let (bundle, root, id) = try self.bundle([[
            "name": "claims spent", "response": response,
            "expected": ["gauges": [["id": "0", "badge": "0", "title": "0",
                                     "usedPercent": 25, "severity": "critical"]]]]])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try #require(QuotaFixture.verify(try descriptor(id), in: bundle))
        #expect(!report.passed,
                "a fixture claiming a spent window was accepted from a mapping reporting none")
    }

    /// And the rule that decides it does nothing when it names nothing.
    /// `allSatisfy` over an empty rule is true, so a descriptor carrying an
    /// empty `criticalWhen` would otherwise report every window spent — a
    /// whole provider permanently red.
    @Test("A rule naming no flag marks no window spent")
    func emptyCriticalRuleMarksNothing() throws {
        let (bundle, root, id) = try self.bundle([[
            "name": "empty rule", "response": response,
            "expected": ["gauges": [["id": "0", "badge": "0", "title": "0", "usedPercent": 25]]]]])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try #require(
            QuotaFixture.verify(try descriptor(id, criticalWhen: [:]), in: bundle))
        #expect(report.passed, Comment(rawValue: report.detail))
    }

    private let response: [String: Any] = ["data": [["pct": 25.0, "id": "w"]]]

    @Test("A quota fixture whose numbers match passes")
    func matchingPasses() throws {
        let (bundle, root, id) = try self.bundle([[
            "name": "matching", "response": response,
            "expected": ["gauges": [["id": "0", "badge": "0", "title": "0", "usedPercent": 25]]]]])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try #require(QuotaFixture.verify(try descriptor(id), in: bundle))
        #expect(report.passed, Comment(rawValue: report.detail))
    }

    @Test("A quota fixture whose numbers are wrong is refused")
    func wrongIsRefused() throws {
        let (bundle, root, id) = try self.bundle([[
            "name": "wrong", "response": response,
            "expected": ["gauges": [["id": "0", "badge": "0", "title": "0", "usedPercent": 99]]]]])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try #require(QuotaFixture.verify(try descriptor(id), in: bundle))
        #expect(!report.passed, "a wrong quota fixture was accepted")
    }

    @Test("A quota fixture declaring neither an expectation nor an error is refused")
    func emptyCaseIsRefused() throws {
        let (bundle, root, id) = try self.bundle([["name": "empty", "response": response]])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try #require(QuotaFixture.verify(try descriptor(id), in: bundle))
        #expect(!report.passed)
    }

    /// Two different absences. A descriptor with no quota block has nothing
    /// to replay and reports nil; one that declares quota and ships no fixture
    /// is a failure, because the mapping is unproven.
    @Test("No quota block is nothing to replay; a missing fixture is a failure")
    func absences() throws {
        let (bundle, root, _) = try self.bundle([])
        defer { try? FileManager.default.removeItem(at: root) }

        let plain: [String: Any] = [
            "formatVersion": 1, "id": "no-quota-\(UUID().uuidString)", "name": "Fixture",
            "process": [:], "source": ["kind": "none", "path": ""]]
        let quotaless = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: plain)).descriptor
        #expect(QuotaFixture.verify(quotaless, in: bundle) == nil)

        let report = try #require(QuotaFixture.verify(
            try descriptor("absent-\(UUID().uuidString)"), in: bundle))
        #expect(!report.passed, "an unproven mapping was reported as fine")
    }
}

/// The third verifier, and the same blind spot. `--verify-harness-installations`
/// reports sixteen probes passing on every release; that says nothing unless
/// it can report one failing.
@Suite("The installation probe evaluator can fail")
struct InstallationEvaluatorTests {

    private func descriptor(match: [String], probes: [[String: Any]]) throws
        -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "probe-\(UUID().uuidString)", "name": "Fixture",
            "process": ["pathContains": match, "installationProbes": probes],
            "source": ["kind": "none", "path": ""]]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    private func probe(_ path: String, expected: Bool, method: String = "synthetic",
                       evidence: String = "https://example.invalid/docs",
                       verifiedAt: String = "2026-09-21") -> [String: Any] {
        ["method": method, "path": path, "name": "tool", "argv0": "tool",
         "expected": expected, "evidence": evidence, "verifiedAt": verifiedAt]
    }

    /// The positive control.
    @Test("Probes that agree with the matcher pass")
    func agreeingProbesPass() throws {
        let report = HarnessInstallationEvaluator.evaluate(try descriptor(
            match: ["/synthetic/"],
            probes: [probe("/synthetic/bin/tool", expected: true),
                     probe("/elsewhere/bin/tool", expected: false)]))
        #expect(report.failures.isEmpty, Comment(rawValue: report.failures.joined(separator: "; ")))
        #expect(report.passed == 2)
    }

    /// The case the whole mechanism exists for: a descriptor claiming to
    /// recognise an installation that its own matcher does not.
    @Test("A probe expecting a match the matcher does not make is a failure")
    func falsePositiveProbeFails() throws {
        let report = HarnessInstallationEvaluator.evaluate(try descriptor(
            match: ["/synthetic/"],
            probes: [probe("/elsewhere/bin/tool", expected: true),
                     probe("/other/bin/tool", expected: false)]))
        #expect(report.passed == 1)
        #expect(report.failures.contains { $0.contains("expected match") })
    }

    /// The other direction, which is how the over-broad matchers were caught:
    /// a path documented as *not* this agent that the matcher claims anyway.
    @Test("A probe expecting no match that the matcher claims is a failure")
    func overBroadMatcherFails() throws {
        let report = HarnessInstallationEvaluator.evaluate(try descriptor(
            match: ["/synthetic/"],
            probes: [probe("/synthetic/bin/tool", expected: true),
                     probe("/synthetic/bin/tool-helper", expected: false)]))
        #expect(report.failures.contains { $0.contains("expected no match") })
    }

    @Test("A harness with no positive probe is reported")
    func missingPositiveProbe() throws {
        let report = HarnessInstallationEvaluator.evaluate(try descriptor(
            match: ["/synthetic/"], probes: [probe("/elsewhere/tool", expected: false)]))
        #expect(report.failures.contains { $0.contains("no positive") })
    }

    @Test("A harness with no negative probe is reported")
    func missingNegativeProbe() throws {
        let report = HarnessInstallationEvaluator.evaluate(try descriptor(
            match: ["/synthetic/"], probes: [probe("/synthetic/tool", expected: true)]))
        #expect(report.failures.contains { $0.contains("no negative") })
    }

    /// A probe is a claim about the world, so it has to say where the claim
    /// came from and when it was checked. The evaluator checks this too, but
    /// a descriptor carrying such a probe never decodes, so the rule is
    /// tested where it is reachable.
    @Test("A probe without usable provenance never decodes", arguments: [
        ("evidence", "http://example.invalid/docs"),
        ("evidence", "not a url"),
        ("verifiedAt", "someday"),
        ("method", "   "),
    ])
    func unprovenProbes(_ field: String, _ value: String) throws {
        var bad = probe("/synthetic/tool", expected: true)
        bad[field] = value
        #expect(throws: (any Swift.Error).self) {
            _ = try descriptor(match: ["/synthetic/"],
                               probes: [bad, probe("/elsewhere/tool", expected: false)])
        }
    }

    /// And the good one still decodes, so the refusals above are not
    /// satisfied by a decoder that rejects every probe.
    @Test("A probe with provenance decodes")
    func provenProbeDecodes() throws {
        _ = try descriptor(match: ["/synthetic/"],
                           probes: [probe("/synthetic/tool", expected: true),
                                    probe("/elsewhere/tool", expected: false)])
    }
}

/// The command-line verifier's aggregation, which is the last link in the
/// release gate. `verify.sh` counts the ticks but decides on the exit code,
/// so a verifier that prints every failure and still returns zero would pass
/// it — and four mutations of this survived before it was testable.
@Suite("The fixture verifier's tally", .serialized)
struct FixtureCLISummaryTests {

    private func descriptor(id: String, sourceKind: String,
                            fixture: String?) throws -> HarnessDescriptor {
        var compatibility: [String: Any] = ["level": "declared", "note": "synthetic"]
        if let fixture { compatibility["fixture"] = fixture }
        var source: [String: Any] = ["kind": sourceKind, "path": ""]
        if sourceKind == "jsonl" { source["glob"] = "*.jsonl" }
        let object: [String: Any] = [
            "formatVersion": 1, "id": id, "name": id, "process": [:],
            "source": source, "compatibility": compatibility]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    /// A descriptor with no session source has no fixture to replay, and must
    /// not be counted as one that passed.
    @Test("Descriptors with no session source are skipped, not passed")
    func noSourceIsSkipped() throws {
        let summary = HarnessCLI.fixtureSummary(
            [try descriptor(id: "quota-only", sourceKind: "none", fixture: nil)],
            in: AppResources.bundle)
        #expect(summary.checked.isEmpty)
        #expect(summary.failed.isEmpty)
        #expect(summary.lines.isEmpty)
    }

    /// A descriptor that declares a fixture which is not there fails, and is
    /// named — a tally that reports the count without the id leaves whoever
    /// reads the release log to go looking.
    @Test("A descriptor whose fixture is missing fails and is named")
    func missingFixtureFails() throws {
        let summary = HarnessCLI.fixtureSummary(
            [try descriptor(id: "broken", sourceKind: "jsonl",
                            fixture: "harness-fixtures/absent.json")],
            in: AppResources.bundle)
        #expect(summary.checked == ["broken"])
        #expect(summary.failed == ["broken"])
        #expect(summary.lines.first?.hasPrefix("✗") == true)
    }

    /// And the shipped ones pass, so the failure above is not simply what
    /// this function always says.
    @Test("Every shipped descriptor with a session source passes")
    func shippedDescriptorsPass() throws {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        let descriptors = try urls.map {
            try HarnessDocument.decode(Data(contentsOf: $0)).descriptor
        }
        let summary = HarnessCLI.fixtureSummary(descriptors, in: AppResources.bundle)
        #expect(summary.failed.isEmpty, Comment(rawValue: summary.failed.joined(separator: ", ")))
        #expect(summary.checked.count >= 10, "too few were checked to prove anything")
        #expect(summary.lines.allSatisfy { $0.hasPrefix("✓") })
    }

    /// The line the release gate actually decides on. It cannot be reached
    /// while every shipped fixture passes, which is exactly why it needs
    /// stating separately: a verifier that prints every failure and returns
    /// zero would go out green.
    @Test("A failure means a nonzero exit, and nothing else does")
    func exitCodeFollowsFailures() {
        let clean = HarnessCLI.FixtureSummary(lines: ["✓ a: ok"], checked: ["a"], failed: [])
        #expect(HarnessCLI.exitCode(for: clean) == 0)

        let broken = HarnessCLI.FixtureSummary(lines: ["✗ a: no"], checked: ["a"], failed: ["a"])
        #expect(HarnessCLI.exitCode(for: broken) != 0)

        // Nothing checked is not a failure here — verify.sh refuses a run
        // that verified nothing, which is where that rule belongs.
        let empty = HarnessCLI.FixtureSummary(lines: [], checked: [], failed: [])
        #expect(HarnessCLI.exitCode(for: empty) == 0)
    }

    /// One line per descriptor checked, so the log and the tally cannot
    /// disagree about how much was looked at.
    @Test("There is exactly one line per descriptor checked")
    func lineCountMatchesCheckedCount() throws {
        let mixed = [try descriptor(id: "quota-only", sourceKind: "none", fixture: nil),
                     try descriptor(id: "broken", sourceKind: "jsonl",
                                    fixture: "harness-fixtures/absent.json")]
        let summary = HarnessCLI.fixtureSummary(mixed, in: AppResources.bundle)
        #expect(summary.lines.count == summary.checked.count)
        #expect(summary.checked.count == 1)
    }
}

/// The other two command-line verifiers, which had the same aggregation and
/// therefore the same gaps. The quota one had an extra: a descriptor that
/// declared quota and produced no report at all was skipped by a `continue`,
/// so a mapping that could not even be attempted counted as fine.
@Suite("The quota and installation tallies", .serialized)
struct RemainingCLISummaryTests {

    private func bundled() throws -> [HarnessDescriptor] {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        return try urls.map { try HarnessDocument.decode(Data(contentsOf: $0)).descriptor }
    }

    private func quotaDescriptor(id: String) throws -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1, "id": id, "name": id, "process": [:],
            "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": "https://example.invalid/u",
                      "windows": ["list": "d", "usedPercent": "p"]]]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
    }

    @Test("A quota descriptor with no fixture is counted and failed, not skipped")
    func missingQuotaFixtureFails() throws {
        let summary = HarnessCLI.quotaSummary(
            [try quotaDescriptor(id: "unproven-\(UUID().uuidString)")],
            in: AppResources.bundle)
        #expect(summary.checked.count == 1, "the descriptor was passed over")
        #expect(summary.failed.count == 1, "an unproven mapping counted as fine")
        #expect(summary.lines.first?.hasPrefix("✗") == true)
    }

    /// The filter lives inside the summary, so a descriptor with no quota
    /// block is passed over rather than counted as a failure — and one that
    /// *does* declare quota is always counted, whatever it yields.
    @Test("Descriptors with no quota block are not counted at all")
    func noQuotaIsNotCounted() throws {
        let plain: [String: Any] = [
            "formatVersion": 1, "id": "no-quota", "name": "None", "process": [:],
            "source": ["kind": "none", "path": ""]]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: plain)).descriptor
        let summary = HarnessCLI.quotaSummary([descriptor], in: AppResources.bundle)
        #expect(summary.checked.isEmpty)
        #expect(summary.failed.isEmpty)
    }

    @Test("Every shipped quota descriptor passes")
    func shippedQuotaPasses() throws {
        let summary = HarnessCLI.quotaSummary(try bundled(), in: AppResources.bundle)
        #expect(summary.failed.isEmpty, Comment(rawValue: summary.failed.joined(separator: ", ")))
        #expect(summary.checked.count >= 7)
    }

    /// A descriptor claiming processes with no probes at all is a failure.
    /// Counting zero probes as a clean run is the vacuous-pass shape again.
    @Test("A descriptor with no probes fails rather than passing vacuously")
    func noProbesFails() throws {
        let object: [String: Any] = [
            "formatVersion": 1, "id": "probeless", "name": "Probeless",
            "process": ["pathContains": ["/synthetic/"]],
            "source": ["kind": "none", "path": ""]]
        let descriptor = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        let summary = HarnessCLI.installationSummary([descriptor])
        #expect(summary.failed == ["probeless"])
    }

    @Test("Every shipped descriptor that claims processes passes its probes")
    func shippedProbesPass() throws {
        let claiming = try bundled().filter {
            !($0.processRule.pathContains ?? []).isEmpty
                || !($0.processRule.names ?? []).isEmpty
                || !($0.processRule.argv0Contains ?? []).isEmpty
        }
        let summary = HarnessCLI.installationSummary(claiming)
        #expect(summary.failed.isEmpty, Comment(rawValue: summary.failed.joined(separator: ", ")))
        #expect(summary.checked.count >= 10)
    }

    @Test("Both tallies print one line per descriptor checked")
    func linesMatchChecked() throws {
        let quota = HarnessCLI.quotaSummary(try bundled().filter { $0.quota != nil },
                                            in: AppResources.bundle)
        #expect(quota.lines.count == quota.checked.count)
        let installs = HarnessCLI.installationSummary(try bundled())
        #expect(installs.lines.count == installs.checked.count)
    }
}

/// The path somebody outside this repository actually walks.
///
/// The five documented steps for adding a quota provider end at
/// `--verify-harness-quota`, which only ever looks at the shipped
/// descriptors. An author with a harness in `~/.antarium/harnesses` could
/// write the mapping and write the fixture and have no way to run one
/// against the other — and the verifier said nothing about the omission, so
/// its list of passes looked like it covered theirs.
///
/// `--check` is the command the seeded README tells them to run, so the
/// fixture is replayed there, from a file beside the descriptor.
@Suite("A descriptor somebody wrote themselves can be checked against a fixture", .serialized)
struct FixtureBesideDescriptorTests {

    private func write(_ name: String, _ object: [String: Any], in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private var descriptor: [String: Any] {
        ["formatVersion": 1, "id": "mine", "name": "Mine",
         "process": [:], "source": ["kind": "none", "path": ""],
         "quota": ["endpoint": "https://api.example.invalid/u",
                   "credential": ["kind": "textFile", "path": "~/.antarium/keys/mine"],
                   "windows": ["single": "info", "usedPercent": "info.pct"]]]
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("beside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A fixture beside the descriptor is found")
    func fixtureIsFound() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try write("mine.json", descriptor, in: root)
        #expect(QuotaFixture.fixtureURL(besideDescriptorAt: d) == nil,
                "a fixture was found before one was written")
        _ = try write("mine.quota-fixture.json", ["response": [:]], in: root)
        #expect(QuotaFixture.fixtureURL(besideDescriptorAt: d)?.lastPathComponent
                == "mine.quota-fixture.json")
    }

    /// A mapping that matches its fixture passes, which is the positive
    /// control: without it everything below is satisfied by a checker that
    /// refuses everything.
    @Test("A mapping that matches its fixture is reported as passing")
    func matchingFixturePasses() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try write("mine.json", descriptor, in: root)
        _ = try write("mine.quota-fixture.json", [
            "cases": [["name": "ordinary",
                       "response": ["info": ["pct": 61.5]],
                       "expected": ["gauges": [["id": "info", "badge": "INF",
                                                "title": "INF", "usedPercent": 61.5]]]]],
        ], in: root)
        #expect(HarnessCheck.run(d.path) == 0)
    }

    /// And one that does not match is a problem, with the difference named.
    /// This is what an author gets instead of finding out at the first fetch.
    @Test("A mapping that disagrees with its fixture is a problem")
    func mismatchingFixtureFails() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try write("mine.json", descriptor, in: root)
        _ = try write("mine.quota-fixture.json", [
            "cases": [["name": "ordinary",
                       "response": ["info": ["pct": 61.5]],
                       "expected": ["gauges": [["id": "info", "badge": "INF",
                                                "title": "INF", "usedPercent": 12.0]]]]],
        ], in: root)
        #expect(HarnessCheck.run(d.path) != 0, "a wrong figure was accepted")
    }

    /// A descriptor with no fixture is not a failure — plenty of harnesses
    /// declare no quota at all — but the omission is said out loud, because
    /// silence is what made this invisible.
    @Test("A descriptor with no fixture beside it still checks clean")
    func noFixtureIsNotAFailure() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try write("mine.json", descriptor, in: root)
        #expect(HarnessCheck.run(d.path) == 0)
    }
}

/// The same path for a session harness, which is most of them.
///
/// A descriptor of somebody's own can declare `compatibility.fixture`, and
/// the fixture was looked for in the app and nowhere else — so a file
/// claiming `fixtureVerified`, with its fixture sitting right beside it, was
/// checked against nothing and `--check` said not a word about either.
@Suite("A session fixture beside a descriptor", .serialized)
struct SessionFixtureBesideDescriptorTests {

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-beside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func descriptor(_ root: URL, fixture: String?) throws -> URL {
        var compatibility: [String: Any] = ["level": "fixtureVerified",
                                            "verifiedAt": "2026-09-22"]
        if let fixture { compatibility["fixture"] = fixture }
        let object: [String: Any] = [
            "formatVersion": 1, "id": "mine", "name": "Mine",
            "process": ["names": ["mine"]],
            "source": ["kind": "jsonl", "path": "~/.mine/sessions", "glob": "*.jsonl"],
            "map": ["cwd": "cwd", "inputTokens": "usage.in", "outputTokens": "usage.out"],
            "compatibility": compatibility,
        ]
        let url = root.appendingPathComponent("mine.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private func fixture(_ root: URL, input: Int) throws {
        let record = #"{"cwd":"/synthetic/p","usage":{"in":\#(input),"out":5}}"# + "\n"
        try JSONSerialization.data(withJSONObject: [
            "files": ["a.jsonl": record],
            "expected": ["sessions": 1, "cwd": "/synthetic/p",
                         "inputTokens": 10, "outputTokens": 5,
                         "cacheRead": 0, "cacheWrite": 0, "toolCalls": 0,
                         "turns": 0, "subAgents": 0, "costUSD": 0],
        ]).write(to: root.appendingPathComponent("mine.fixture.json"))
    }

    @Test("A fixture beside the descriptor is replayed and can pass")
    func besideFixturePasses() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try descriptor(root, fixture: "mine.fixture.json")
        try fixture(root, input: 10)
        #expect(HarnessCheck.run(d.path) == 0)
    }

    /// The positive control matters more here than usual: a verifier that
    /// cannot find the fixture and one that finds it and agrees both look
    /// like success from outside.
    @Test("A fixture whose numbers are wrong is a problem, with the field named")
    func besideFixtureCanFail() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try descriptor(root, fixture: "mine.fixture.json")
        try fixture(root, input: 999)
        #expect(HarnessCheck.run(d.path) != 0)

        let decoded = try HarnessDocument.decode(try Data(contentsOf: d)).descriptor
        let report = HarnessCompatibility.verifyFixture(
            decoded, in: AppResources.bundle, beside: root)
        #expect(report.detail.contains("inputTokens"),
                Comment(rawValue: "the difference was not named: \(report.detail)"))
    }

    /// Claiming the level without declaring a fixture is the shape that
    /// looked verified and was not.
    @Test("Claiming fixtureVerified with no fixture declared is a problem")
    func claimWithoutFixture() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try descriptor(root, fixture: nil)
        #expect(HarnessCheck.run(d.path) != 0)
    }

    /// The fixture is a file beside the descriptor, not a way to read one
    /// from anywhere on the disk.
    ///
    /// Note what actually enforces that: the resolver takes only the last
    /// component of the declared path, so none of these reach outside the
    /// folder however they are spelled. The explicit guard beside it is
    /// redundant and says so — mutating it away changes no answer, which is
    /// why there is no catalogue entry for it. This test holds the property
    /// rather than the line.
    @Test("A fixture path that climbs out of the folder is not resolved",
          arguments: ["../elsewhere.json", "/etc/passwd", "a/../../b.json"])
    func fixturePathCannotClimb(path: String) throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try descriptor(root, fixture: path)
        try fixture(root, input: 10)
        #expect(HarnessCheck.run(d.path) != 0, "a fixture outside the folder was read")
    }

    /// Every field of the snapshot is compared, including one nobody thought
    /// to list: the differences come from the encoded form, so a field added
    /// later cannot quietly stop being checked.
    @Test("Differences are named field by field")
    func differencesAreNamed() {
        var a = HarnessCompatibility.Snapshot(
            sessions: 1, inputTokens: 10, outputTokens: 5, cacheRead: 0, cacheWrite: 0,
            contextTokens: nil, toolCalls: 0, turns: 0, subAgents: 0, costUSD: 0)
        var b = a
        #expect(HarnessCompatibility.Snapshot.differences(expected: a, actual: b).isEmpty)
        b.turns = 3
        a.cwd = "/one"
        let found = HarnessCompatibility.Snapshot.differences(expected: a, actual: b)
        #expect(found.contains { $0.hasPrefix("turns") })
        #expect(found.contains { $0.hasPrefix("cwd") })
        #expect(found.count == 2, Comment(rawValue: "\(found)"))
    }
}

/// The documentation is the contract for somebody outside this repository:
/// it is the only place the filename is stated, and they cannot read the
/// source to find out. A suffix changed in one and not the other leaves them
/// with a fixture nothing looks at and no way to tell.
@Suite("The documented fixture names are the ones the code looks for")
struct DocumentedFixtureNameTests {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("The quota fixture suffix in the docs is the one that resolves")
    func quotaSuffixMatches() throws {
        let doc = try String(contentsOf: root.appendingPathComponent("docs/TECHNICAL.md"),
                             encoding: .utf8)
        #expect(doc.contains("<id>.quota-fixture.json"),
                "the documentation no longer names the fixture a reader must write")

        // The name the code actually resolves, asked of the code.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let descriptor = dir.appendingPathComponent("mine.json")
        try Data("{}".utf8).write(to: descriptor)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("mine.quota-fixture.json"))
        #expect(QuotaFixture.fixtureURL(besideDescriptorAt: descriptor) != nil,
                "the documented name is not the one the code looks for")
    }

    /// And the seeded README, which is the only instruction most people ever
    /// read — it sits in the folder they are editing.
    @Test("The seeded README names the same file")
    func seededReadmeAgrees() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Antarium/Core/HarnessDescriptor.swift"),
            encoding: .utf8)
        #expect(source.contains("quota-fixture.json"),
                "the README beside a user's harnesses no longer mentions the fixture")
        #expect(source.contains("--check"),
                "the README no longer names the command that checks their work")
    }
}
