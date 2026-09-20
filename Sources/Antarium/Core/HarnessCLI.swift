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
        var failures = 0
        for descriptor in descriptors {
            guard descriptor.source.kind != .none else { continue }
            let report = HarnessCompatibility.verifyFixture(descriptor, in: AppResources.bundle)
            let passed = report.status == .fixtureVerified
            print("\(passed ? "✓" : "✗") \(descriptor.id): \(report.detail)"
                + (report.verifiedAt.map { " (\($0))" } ?? ""))
            if !passed { failures += 1 }
        }
        return failures == 0 ? 0 : 1
    }

    /// Replays a recorded response shape through every descriptor's `quota`
    /// mapping. No account, no network, no installed agent — a wrong field
    /// path fails here rather than on a stranger's Mac.
    static func verifyBundledQuota() -> Int32 {
        let descriptors = bundledDescriptors().filter { $0.quota != nil }
        var failures = 0
        for descriptor in descriptors {
            guard let report = QuotaFixture.verify(descriptor, in: AppResources.bundle) else { continue }
            print("\(report.passed ? "✓" : "✗") \(report.id): \(report.detail)"
                + (report.verifiedAt.map { " (\($0))" } ?? ""))
            if !report.passed { failures += 1 }
        }
        if descriptors.isEmpty { print("no descriptor declares a quota block") }
        return failures == 0 ? 0 : 1
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

        var failures = 0
        for descriptor in descriptors {
            let report = HarnessInstallationEvaluator.evaluate(descriptor)
            let passed = report.failures.isEmpty && report.total > 0
            print("\(passed ? "✓" : "✗") \(descriptor.id): \(report.passed)/\(report.total) probes"
                + (report.failures.isEmpty ? "" : " — \(report.failures.joined(separator: "; "))"))
            if !passed { failures += 1 }
        }
        return failures == 0 ? 0 : 1
    }
}
