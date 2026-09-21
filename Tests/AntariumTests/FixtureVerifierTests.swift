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
        ["sessions": 1, "cwd": "/synthetic", "inputTokens": inputTokens,
         "outputTokens": 5, "cacheRead": 0, "cacheWrite": 0, "contextTokens": 0,
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

    private func descriptor(_ id: String) throws -> HarnessDescriptor {
        let object: [String: Any] = [
            "formatVersion": 1, "id": id, "name": "Fixture", "process": [:],
            "source": ["kind": "none", "path": ""],
            "quota": ["endpoint": "https://example.invalid/u",
                      "windows": ["list": "data", "usedPercent": "pct"]]]
        return try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
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
