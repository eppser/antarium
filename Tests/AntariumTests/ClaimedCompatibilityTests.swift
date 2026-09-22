import Foundation
import Testing
@testable import Antarium

/// What a harness may claim about itself.
///
/// HarnessCompatibility opens with the rule: "A declaration in JSON never
/// upgrades itself: `fixtureVerified` is reported only when the fixture
/// executes through the real engine and exact expected values match." The
/// settings panel prints that status beside every harness, and a harness can
/// come from anybody — the folder is documented as yours to edit and to add
/// to. A file that could assert its own verification would make the column
/// worthless.
///
/// Nothing tested it. The rule turns out to be enforced in two places at
/// once, which is worth pinning separately: the decoder will not even load
/// the higher claims without a fixture, and the verifier reports evidence
/// rather than the claim for the ones it does load.
@Suite("A harness cannot certify itself")
struct ClaimedCompatibilityTests {

    private func descriptor(level: String, fixture: String? = nil,
                            verifiedAt: String? = "2026-01-01",
                            source: [String: Any] = ["kind": "none", "path": ""])
        throws -> HarnessDescriptor {
        var compatibility: [String: Any] = ["level": level]
        if let verifiedAt { compatibility["verifiedAt"] = verifiedAt }
        if let fixture { compatibility["fixture"] = fixture }
        return try HarnessDocument.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "id": "claim", "name": "Claim", "process": [:],
            "source": source, "map": ["cwd": "cwd"],
            "compatibility": compatibility,
        ])).descriptor
    }

    /// The claims that assert evidence cannot be made without any. Refused
    /// when the file is read, so such a harness never reaches the panel.
    @Test("A claim of verification with no fixture is refused outright",
          arguments: ["fixtureVerified", "liveVerified"])
    func highClaimsNeedAFixture(level: String) {
        #expect(throws: (any Error).self) { try descriptor(level: level) }
    }

    /// And it must say when. A claim of verification with no date is a claim
    /// that cannot go stale, which is the one kind that never needs
    /// revisiting — the panel prints the date beside the status precisely so
    /// a reader can judge how old the evidence is.
    @Test("A claim of verification with no date is refused",
          arguments: ["fixtureVerified", "liveVerified"])
    func highClaimsNeedADate(level: String) {
        #expect(throws: (any Error).self) {
            try descriptor(level: level, fixture: "c.fixture.json", verifiedAt: nil)
        }
    }

    /// The two that claim nothing are taken at face value, because they
    /// assert nothing to check.
    @Test("A claim of nothing is reported as that", arguments: [
        ("experimental", HarnessCompatibility.Status.experimental),
        ("declared", HarnessCompatibility.Status.declared),
    ])
    func modestClaimsAreKept(level: String, expected: HarnessCompatibility.Status) throws {
        let report = HarnessCompatibility.verifyFixture(
            try descriptor(level: level), in: AppResources.bundle)
        #expect(report.status == expected)
    }

    /// And a claim backed by a fixture that does not match is reported as
    /// broken, not as verified. This is the case the rule is really about:
    /// the fixture exists, so the file loads, and the numbers are wrong.
    @Test("A claim whose fixture disagrees is incompatible, not verified")
    func failingFixtureIsNotVerified() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: [
            "files": ["a.jsonl": #"{"cwd":"/synthetic/p"}"# + "\n"],
            // Claims a session that is not there.
            "expected": ["sessions": 9, "cwd": "/synthetic/p",
                         "inputTokens": 0, "outputTokens": 0, "cacheRead": 0,
                         "cacheWrite": 0, "toolCalls": 0, "turns": 0,
                         "subAgents": 0, "costUSD": 0],
        ]).write(to: root.appendingPathComponent("c.fixture.json"))

        let d = try descriptor(level: "liveVerified", fixture: "c.fixture.json",
                               source: ["kind": "jsonl", "path": "~/.nowhere",
                                        "glob": "*.jsonl"])
        let report = HarnessCompatibility.verifyFixture(d, in: AppResources.bundle, beside: root)
        #expect(report.status == .incompatible,
                Comment(rawValue: "a harness certified itself as \(report.status.rawValue)"))
    }

    /// The positive control, and the sharper half of the rule: a fixture that
    /// matches reports what was demonstrated — `fixtureVerified` — whatever
    /// the file claimed above it. A harness claiming the highest level is not
    /// awarded it for passing a lower bar.
    @Test("A claim backed by a matching fixture reports what was shown, not what was claimed")
    func passingFixtureReportsEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claim-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: [
            "files": ["a.jsonl": #"{"cwd":"/synthetic/p"}"# + "\n"],
            "expected": ["sessions": 1, "cwd": "/synthetic/p",
                         "inputTokens": 0, "outputTokens": 0, "cacheRead": 0,
                         "cacheWrite": 0, "toolCalls": 0, "turns": 0,
                         "subAgents": 0, "costUSD": 0],
        ]).write(to: root.appendingPathComponent("c.fixture.json"))

        let d = try descriptor(level: "liveVerified", fixture: "c.fixture.json",
                               source: ["kind": "jsonl", "path": "~/.nowhere",
                                        "glob": "*.jsonl"])
        let report = HarnessCompatibility.verifyFixture(d, in: AppResources.bundle, beside: root)
        #expect(report.status == .fixtureVerified,
                Comment(rawValue: "reported \(report.status.rawValue)"))
        // Never the claimed level: there is no status that means a live
        // account was seen, because nothing here can see one.
        #expect(HarnessCompatibility.Status(rawValue: "liveVerified") == nil,
                "a status exists that no evidence in this app can establish")
    }
}
