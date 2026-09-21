import Foundation
import AntariumHarnessSDK

enum HarnessCLI {
    static func migrate(input: String, output: String) -> Int32 {
        do {
            let source = URL(fileURLWithPath: input.expandingTilde)
            let destination = URL(fileURLWithPath: output.expandingTilde)
            let migration = try HarnessConfigMigration.migrate(Data(contentsOf: source))
            try migration.data.write(to: destination, options: .atomic)
            print("migrated \(source.path) -> \(destination.path) (format \(HarnessConfig.currentFormatVersion))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("migration failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private struct EvaluationOutput: Codable {
        let harness: String
        let sessions: [HarnessEngine.Session]
        let metrics: HarnessEngine.EvaluationMetrics
        let health: String?
    }

    static func evaluate(_ path: String) -> Int32 {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path.expandingTilde))
            let descriptor = try HarnessDocument.decode(data).descriptor
            let result = HarnessEngine.evaluate(descriptor)
            let output = EvaluationOutput(harness: descriptor.id,
                                          sessions: result.sessions,
                                          metrics: result.metrics,
                                          health: HarnessEngine.health(for: descriptor.id)?.message)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(output), as: UTF8.self))
            return output.health == nil ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("evaluation failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func verifyBundledFixtures() -> Int32 {
        let descriptors = (AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses") ?? [])
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap {
                    try? HarnessDocument.decode($0).descriptor
                }
            }
        let summary = fixtureSummary(descriptors, in: AppResources.bundle)
        for line in summary.lines { print(line) }
        return exitCode(for: summary)
    }

    /// The release gate counts the ticks but decides on this. It cannot be
    /// reached from a test while every shipped fixture passes, so it is a
    /// function of the summary rather than a line inside the command.
    static func exitCode(for summary: FixtureSummary) -> Int32 {
        summary.failed.isEmpty ? 0 : 1
    }

    /// One line per descriptor and the ids that failed.
    ///
    /// Returned rather than printed so the aggregation can be tested: the
    /// release gate counts the ticks but decides on the exit code, so a
    /// verifier that reports every failure and still returns zero would pass
    /// it. Four mutations of this aggregation survived before it was a
    /// function.
    struct FixtureSummary {
        let lines: [String]
        let checked: [String]
        let failed: [String]
    }

    static func fixtureSummary(_ descriptors: [HarnessDescriptor],
                               in bundle: Bundle) -> FixtureSummary {
        var lines: [String] = [], checked: [String] = [], failed: [String] = []
        for descriptor in descriptors {
            // A descriptor with no session source has no fixture to replay;
            // its quota mapping is checked by the other verifier.
            guard descriptor.source.kind != .none else { continue }
            let report = HarnessCompatibility.verifyFixture(descriptor, in: bundle)
            let passed = report.status == .fixtureVerified
            checked.append(descriptor.id)
            if !passed { failed.append(descriptor.id) }
            lines.append("\(passed ? "✓" : "✗") \(descriptor.id): \(report.detail)"
                + (report.verifiedAt.map { " (\($0))" } ?? ""))
        }
        return FixtureSummary(lines: lines, checked: checked, failed: failed)
    }

    /// Replays a recorded response shape through every descriptor's `quota`
    /// mapping. No account, no network, no installed agent — a wrong field
    /// path fails here rather than on a stranger's Mac.
    static func verifyBundledQuota() -> Int32 {
        let descriptors = bundledDescriptors().filter { $0.quota != nil }
        let summary = quotaSummary(bundledDescriptors(), in: AppResources.bundle)
        for line in summary.lines { print(line) }
        if descriptors.isEmpty { print("no descriptor declares a quota block") }
        return exitCode(for: summary)
    }

    /// A descriptor that declares quota and yields no report is a failure,
    /// not something to pass over. The `continue` this replaces skipped it
    /// silently, so a mapping that could not even be attempted counted as
    /// fine.
    static func quotaSummary(_ descriptors: [HarnessDescriptor],
                             in bundle: Bundle) -> FixtureSummary {
        var lines: [String] = [], checked: [String] = [], failed: [String] = []
        // Filtered here rather than by the caller, so "produced no report"
        // means something definite: every descriptor reaching the loop
        // declares a quota block, and one that then yields nothing has a
        // mapping that could not even be attempted.
        for descriptor in descriptors where descriptor.quota != nil {
            checked.append(descriptor.id)
            guard let report = QuotaFixture.verify(descriptor, in: bundle) else {
                failed.append(descriptor.id)
                lines.append("✗ \(descriptor.id): declares quota but produced no report")
                continue
            }
            if !report.passed { failed.append(report.id) }
            lines.append("\(report.passed ? "✓" : "✗") \(report.id): \(report.detail)"
                + (report.verifiedAt.map { " (\($0))" } ?? ""))
        }
        return FixtureSummary(lines: lines, checked: checked, failed: failed)
    }

    /// Reports what a first run would switch on, and why.
    ///
    /// Read-only unless `apply` is given, and even then it goes through
    /// `applyIfNeeded`, which declines when a choice already exists — so
    /// running it against a live installation cannot overwrite one.
    static func detectAgents(apply: Bool = false) -> Int32 {
        HarnessDescriptor.seed()
        let providers = ProviderRegistry.all
        let sessions = AgentAutoEnable.sessionsPresent()
        let evidence = AgentAutoEnable.evidence(providers: providers, sessionsPresent: sessions)
        let chosen = AgentAutoEnable.resolve(evidence, fallback: providers.map(\.id))
        print("settings   \(Config.directory.path)")
        print("providers  \(providers.count), showing at most \(AgentAutoEnable.limit)")
        print("recorded   " + (Settings.unconfigured(recorded: Settings.recordedAgents)
            ? "nothing yet — a first run would choose"
            : "a choice already exists and would be left alone"))
        for item in evidence.sorted(by: { ($0.strength, $1.id) > ($1.strength, $0.id) }) {
            let why: String
            switch (item.signedIn, item.hasSessions) {
            case (true, true):   why = "signed in, sessions here"
            case (true, false):  why = "signed in"
            case (false, true):  why = "sessions here, not signed in"
            case (false, false): why = "no trace on this Mac"
            }
            print("\(chosen.contains(item.id) ? "●" : "○") \(item.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(why)")
        }
        if apply {
            if let written = AgentAutoEnable.applyIfNeeded(providers: providers) {
                print("wrote      enabledAgents = \(written.sorted().joined(separator: ", "))")
            } else {
                print("wrote      nothing — a recorded choice is the user's to change")
            }
        }
        return 0
    }

    /// Every shipped descriptor, decoded once.
    static func bundledDescriptors() -> [HarnessDescriptor] {
        (AppResources.bundle.urls(forResourcesWithExtension: "json", subdirectory: "harnesses") ?? [])
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? HarnessDocument.decode($0).descriptor }
            }
            .sorted { $0.id < $1.id }
    }

    /// Deterministically checks every declared install layout without running
    /// an installer. Each harness owns its evidence matrix in JSON; this code
    /// remains generic when a new package manager or harness is added.
    static func verifyBundledInstallations() -> Int32 {
        let descriptors = (AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses") ?? [])
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap {
                    try? HarnessDocument.decode($0).descriptor
                }
            }
            .filter {
                !($0.processRule.pathContains ?? []).isEmpty
                    || !($0.processRule.names ?? []).isEmpty
                    || !($0.processRule.argv0Contains ?? []).isEmpty
            }
            .sorted { $0.id < $1.id }

        let summary = installationSummary(descriptors)
        for line in summary.lines { print(line) }
        return exitCode(for: summary)
    }

    /// A descriptor that claims processes must carry probes that pass. Zero
    /// probes is a failure rather than a vacuous success — that is what
    /// `report.total > 0` is for, and it had nothing holding it.
    static func installationSummary(_ descriptors: [HarnessDescriptor]) -> FixtureSummary {
        var lines: [String] = [], checked: [String] = [], failed: [String] = []
        for descriptor in descriptors {
            let report = HarnessInstallationEvaluator.evaluate(descriptor)
            // `total > 0` cannot decide this on its own: an empty probe list
            // already fails the evaluator's "no positive probe" and "no
            // negative probe" rules, so `failures.isEmpty` implies probes of
            // both polarities exist. Kept as a statement of intent; no
            // mutation of it can be caught.
            let passed = report.failures.isEmpty && report.total > 0
            checked.append(descriptor.id)
            if !passed { failed.append(descriptor.id) }
            lines.append("\(passed ? "✓" : "✗") \(descriptor.id): \(report.passed)/\(report.total) probes"
                + (report.failures.isEmpty ? "" : " — \(report.failures.joined(separator: "; "))"))
        }
        return FixtureSummary(lines: lines, checked: checked, failed: failed)
    }
}
