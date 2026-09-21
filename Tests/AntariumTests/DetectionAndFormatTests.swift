import Foundation
import Testing
@testable import Antarium

/// Detection is the whole of "it should already know what I run": the first
/// run enables the agents this Mac has, and it decides that from whether each
/// harness's session store exists. Replacing that existence check with `true`
/// made every agent look installed and failed no test — which would have
/// turned a considered default into a list of everything.
@Suite("Agent detection reads the disk", .serialized)
struct AgentDetectionTests {

    @Test("An agent is found only when its session store is actually there")
    func detectionRequiresTheStoreToExist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("detect-\(UUID().uuidString)")
        let present = root.appendingPathComponent("present")
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("absent")

        func descriptor(_ id: String, path: String) throws -> HarnessDescriptor {
            try HarnessDocument.decode(JSONSerialization.data(withJSONObject: [
                "formatVersion": 1, "id": id, "name": id, "process": [:],
                "source": ["kind": "jsonl", "path": path, "glob": "*.jsonl"],
            ])).descriptor
        }
        let findings = Onboarding.harnesses([
            try descriptor("here", path: present.path),
            try descriptor("gone", path: absent.path),
        ])

        // Both answers have to be reachable, or claiming everything is
        // installed looks the same as reading the disk.
        #expect(findings.first { $0.id == "here" }?.found == true)
        #expect(findings.first { $0.id == "gone" }?.found == false)
        // "No trace" rather than "not installed": the agent's id is not a
        // command on this Mac either, and neither miss proves it is absent.
        #expect(findings.first { $0.id == "gone" }?.detail == "no trace on this Mac")
        #expect(findings.first { $0.id == "gone" }?.installedUnused == false)
        // The present one reports where it was found, with the home directory
        // shortened rather than spelled out.
        #expect(findings.first { $0.id == "here" }?.detail.contains("present") == true)
    }

    @Test("A harness with no session store is not offered as found")
    func quotaOnlyHarnessesAreNotSessionFindings() throws {
        // Copilot declares no session store: it exists for the menu bar gauge.
        // It used to fail the existence check and appear as "not installed
        // here" directly under its own "signed in" row.
        //
        // Asked of the live catalog this passes on a machine with no
        // harnesses seeded, because nothing is listed at all. The descriptors
        // come from the bundle so both a quota-only and a session harness are
        // present to tell apart.
        let bundled = HarnessCLI.bundledDescriptors()
        let copilot = try #require(bundled.first { $0.id == "copilot" })
        let withSessions = try #require(bundled.first { !$0.source.path.isEmpty })
        let findings = Onboarding.harnesses([copilot, withSessions])
        #expect(!findings.contains { $0.id == "copilot" })
        #expect(findings.contains { $0.id == withSessions.id })
    }
}

/// The strings a row shows when there is nothing to show. Each absent case is
/// a distinct statement — no reset scheduled, never seen — and collapsing one
/// into a number or a time makes absence read as data.
@Suite("Absent values read as absent")
struct FormatAbsenceTests {

    @Test("No reset date says so, rather than showing a countdown")
    func countdownHasAnAbsentCase() {
        #expect(Format.shortCountdown(to: nil) == "—")
        #expect(Format.longReset(nil) == "no scheduled reset")
        // And a real date still formats. `now` is passed explicitly: taking
        // it from the clock made the span 46.998 minutes by the time it was
        // formatted, which truncates to "46m" and fails for no reason.
        let now = Date()
        let soon = now.addingTimeInterval(47 * 60)
        #expect(Format.shortCountdown(to: soon, now: now) == "47m")
        #expect(Format.longReset(soon, now: now).hasPrefix("resets in 47m"))
    }

    @Test("Never-seen is not the same as seen just now")
    func ageHasAnAbsentCase() {
        #expect(Format.age(nil) == "never")
        #expect(Format.age(Date()) == "just now")
        #expect(Format.age(Date().addingTimeInterval(-600)) == "10 min ago")
    }

    @Test("A reset already past reads as now, not as a negative span")
    func pastResetsDoNotGoNegative() {
        let past = Date().addingTimeInterval(-60)
        #expect(Format.shortCountdown(to: past) == "now")
        #expect(Format.longReset(past) == "resetting now")
        // And a date in the future never rounds down to zero minutes.
        #expect(Format.shortCountdown(to: Date().addingTimeInterval(5)) == "1m")
    }
}

/// An agent that is installed and has not been run yet.
///
/// The onboarding screen listed everything without a session store under
/// "Also supported, not installed here". For an agent installed this morning
/// and not yet started that is a false statement about the user's own Mac,
/// and it is the same collapse the rest of this app is careful about: absent,
/// empty and unknown are three answers, not one.
@Suite("Installed and unused is not the same as absent")
struct InstalledButUnusedTests {

    private func descriptor(_ id: String, path: String, process: String) throws
        -> HarnessDescriptor {
        try HarnessDocument.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "id": id, "name": id,
            "process": ["names": [process]],
            "source": ["kind": "jsonl", "path": path, "glob": "*.jsonl"],
        ])).descriptor
    }

    private func findings(_ resolves: Set<String>) throws -> [Onboarding.Finding] {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-\(UUID().uuidString)")
        return Onboarding.harnesses(
            [try descriptor("unused", path: absent.path, process: "an-agent"),
             try descriptor("missing", path: absent.path, process: "another-agent")],
            resolve: { resolves.contains($0) ? "/synthetic/bin/\($0)" : nil })
    }

    @Test("An agent whose command is here but has no sessions says so")
    func installedUnusedIsItsOwnAnswer() throws {
        let found = try findings(["an-agent"])
        let unused = try #require(found.first { $0.id == "unused" })
        #expect(unused.found == false, "an unused agent must not earn a bar slot")
        #expect(unused.installedUnused)
        #expect(unused.detail == "here, no sessions yet")
    }

    @Test("An agent with neither sessions nor a command is not called missing")
    func absentIsNotAClaimOfAbsence() throws {
        let found = try findings(["an-agent"])
        let missing = try #require(found.first { $0.id == "missing" })
        #expect(missing.found == false)
        #expect(missing.installedUnused == false)
        #expect(missing.detail == "no trace on this Mac",
                "a miss on both proves neither; several agents ship as apps, not commands")
    }

    /// The evidence a first run acts on is unchanged. An agent that has never
    /// been used still earns nothing, because that item could only say
    /// "sign in" — which is the whole reason these are two fields and not one.
    @Test("Being installed and unused earns no menu bar slot")
    func unusedEarnsNothing() throws {
        let found = try findings(["an-agent", "another-agent"])
        let anyFound = found.contains { $0.found }
        let allInstalled = found.allSatisfy(\.installedUnused)
        #expect(anyFound == false)
        #expect(allInstalled)
    }

    /// Used first, then present but unused, then the rest — and by name
    /// inside each group, so two Macs with the same agents agree.
    @Test("The three states are ordered, and ties break on name")
    func orderIsStable() throws {
        let ids = try findings(["an-agent"]).map(\.id)
        #expect(ids == ["unused", "missing"])
    }
}
