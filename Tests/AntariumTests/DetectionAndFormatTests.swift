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

    /// The link between "what is installed here" and "what the bar opens
    /// to". Detection has its own tests and the first-run policy has its own
    /// tests, and nothing joined them: replacing the whole of
    /// `sessionsPresent` with an empty set failed nothing, because every
    /// provider this developer's Mac enables happens to be signed in as well,
    /// so the sessions half of the evidence never decided anything here.
    ///
    /// Driven from synthetic descriptors pointing at temporary directories,
    /// so it says the same thing on a Mac with no agent installed on it at
    /// all.
    @Test("An agent known only by its sessions still earns a place in the bar")
    func detectionFeedsTheFirstRun() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-run-\(UUID().uuidString)")
        let used = root.appendingPathComponent("used")
        try FileManager.default.createDirectory(at: used, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func descriptor(_ id: String, path: String) throws -> HarnessDescriptor {
            try HarnessDocument.decode(JSONSerialization.data(withJSONObject: [
                "formatVersion": 1, "id": id, "name": id, "process": [:],
                "source": ["kind": "jsonl", "path": path, "glob": "*.jsonl"],
            ])).descriptor
        }
        let catalogue = [
            try descriptor("used-here", path: used.path),
            try descriptor("never-used", path: root.appendingPathComponent("gone").path),
        ]

        let sessions = AgentAutoEnable.sessionsPresent(catalogue)
        #expect(sessions == ["used-here"],
                "detection reported \(sessions.sorted()) for a machine with one store")

        // And the evidence that reaches the first-run decision carries it.
        // Neither provider is signed in, so sessions are the only thing that
        // can distinguish them — which is the case the live Mac cannot test.
        let evidence = AgentAutoEnable.evidence(
            providers: [], sessionsPresent: sessions)
        #expect(evidence.isEmpty, "no providers were given, so there is no evidence to have")

        let chosen = AgentAutoEnable.resolve([
            AgentAutoEnable.Evidence(id: "used-here", signedIn: false,
                                     hasSessions: sessions.contains("used-here")),
            AgentAutoEnable.Evidence(id: "never-used", signedIn: false,
                                     hasSessions: sessions.contains("never-used")),
        ], fallback: ["fallback"])
        #expect(chosen == ["used-here"],
                "the bar opened to \(chosen.sorted()) on a machine with one agent used on it")
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

/// The app says the same thing about finding nothing, wherever it says it.
///
/// There were three phrases. The onboarding screen said "not installed
/// here", the settings list said "Not found on this Mac", and
/// `--detect-agents` said "no trace on this Mac". Only the last is true, and
/// the first is a claim about the user's Mac the app is in no position to
/// make: an agent can be installed without having been run, several ship as
/// applications rather than commands on PATH, and a GUI-launched app searches
/// a shorter PATH than a shell does.
@Suite("Finding nothing is reported the same way everywhere")
struct AbsenceVocabularyTests {

    /// Every Swift file the app ships, so the rule cannot be outrun by
    /// writing the claim somewhere new.
    static func sources() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // Recursive, so a folder added later is covered without anybody
        // remembering to add it here.
        let base = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
            .sorted()
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("The phrase reports what was seen, not what is concluded")
    func phraseIsObservational() {
        #expect(Onboarding.absent == "no trace on this Mac")
    }

    /// Nothing may state that an agent is not installed, because nothing here
    /// can establish it.
    /// Every source, not a list of four.
    ///
    /// The first version named the four surfaces that were wrong at the time,
    /// and two providers went on saying "Amp isn't installed on this Mac"
    /// from a failed PATH lookup — which is the same over-claim, in the two
    /// places most exposed to it, because a command installed through nvm,
    /// volta, mise or a custom prefix is in none of the places this app
    /// looks. A rule that lists its subjects only ever covers the instances
    /// that prompted it.
    /// The count is asserted separately, because a parameterised test over an
    /// empty list passes.
    @Test("Every shipped source is scanned for the claim")
    func scanCoversEverySource() throws {
        let count = try Self.sources().count
        #expect(count > 70, "only \(count) sources were scanned")
    }

    @Test("No source claims an agent is not installed", arguments: try sources())
    func noSurfaceClaimsAbsence(_ path: String) throws {
        let text = try source(path)
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            // The comments explaining the change quote the phrases it
            // replaced; a rule that cannot tell prose from code makes
            // recording a mistake impossible.
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                  !line.trimmingCharacters(in: .whitespaces).hasPrefix("///") else { continue }
            for claim in ["not installed", "isn't installed", "Not found on this Mac",
                          "not on this Mac"] {
                #expect(!line.contains(claim), Comment(rawValue:
                    "\(path):\(index + 1) states \"\(claim)\", which none of these checks proves"))
            }
        }
    }

    /// And each surface goes through the one constant rather than spelling it
    /// again, which is how three of them drifted apart in the first place.
    @Test("Each surface reads the phrase from one place", arguments: [
        "Sources/Antarium/Core/HarnessCLI.swift",
        "Sources/Antarium/UI/OnboardingView.swift",
        "Sources/Antarium/UI/SettingsView.swift",
    ])
    func surfacesShareTheConstant(_ path: String) throws {
        #expect(try source(path).contains("Onboarding.absent"),
                Comment(rawValue: "\(path) spells the phrase itself"))
    }
}
