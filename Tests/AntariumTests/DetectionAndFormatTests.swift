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
        #expect(findings.first { $0.id == "gone" }?.detail == "not on this Mac")
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
