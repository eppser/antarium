import Foundation
import Testing
import AntariumHarnessSDK
@testable import Antarium

@Suite("Harness installation evaluations", .serialized)
struct HarnessInstallationEvaluationTests {
    private func bundledDescriptors() throws -> [HarnessDescriptor] {
        try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
            .map { try HarnessDocument.decode(Data(contentsOf: $0)).descriptor }
            .sorted { $0.id < $1.id }
    }

    @Test("Every process-backed harness proves positive and negative synthetic layouts")
    func bundledHarnessesCarryExecutableInstallationEvaluations() throws {
        let descriptors = try bundledDescriptors().filter {
            !$0.processRule.pathContains.orEmpty.isEmpty
                || !$0.processRule.names.orEmpty.isEmpty
                || !$0.processRule.argv0Contains.orEmpty.isEmpty
        }
        // Counted, not merely non-empty. Every assertion below is inside
        // a loop over this list, so a filter that stopped matching would
        // leave the test green having checked one harness, or none.
        #expect(descriptors.count >= 15,
                "only \(descriptors.count) process-backed harnesses were examined")

        for descriptor in descriptors {
            let probes = descriptor.processRule.installationProbes.orEmpty
            #expect(probes.contains(where: { $0.expected }),
                    "\(descriptor.id) needs a positive installation probe")
            #expect(probes.contains(where: { !$0.expected }),
                    "\(descriptor.id) needs a negative collision/helper probe")

            let report = HarnessInstallationEvaluator.evaluate(descriptor)
            #expect(report.failures.isEmpty,
                    "\(descriptor.id): \(report.failures.joined(separator: "; "))")
            #expect(report.passed == probes.count)
        }
    }

    @Test("Installation probes are evidence, not undocumented assumptions")
    func probesCarryFreshOfficialEvidenceAndSyntheticDataOnly() throws {
        // Counted: every assertion here is two loops deep, so a day with no
        // probes at all would pass having examined none of them.
        var examined = 0
        for descriptor in try bundledDescriptors() {
            for probe in descriptor.processRule.installationProbes.orEmpty {
                examined += 1
                let evidence = try #require(URL(string: probe.evidence))
                #expect(evidence.scheme == "https")
                #expect(evidence.host != nil)
                #expect(validDay(probe.verifiedAt))
                #expect(!probe.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(!probe.path.contains("/Users/"),
                        "Probe paths must be portable fixtures, not local machine data")
            }
        }
        #expect(examined >= 30,
                "only \(examined) probes were examined, and sixteen harnesses carry several each")
    }

    @Test("The evaluator uses the production matcher for all process evidence")
    func evaluatorCatchesMatcherDrift() throws {
        let data = Data(#"""
        {
          "formatVersion":1,"id":"probe-agent","name":"Probe Agent",
          "process":{
            "pathContains":["/@scope/probe-agent/"],
            "names":["probe-agent"],
            "argv0Contains":["/probe-agent/cli.js"],
            "installationProbes":[
              {"method":"npm-native","path":"/fixture/node_modules/@scope/probe-agent/bin/run","name":"run","argv0":"run","expected":true,"evidence":"https://example.invalid/install","verifiedAt":"2026-08-26"},
              {"method":"npm-script","path":"/usr/bin/node","name":"node","argv0":"/fixture/probe-agent/cli.js","expected":true,"evidence":"https://example.invalid/install","verifiedAt":"2026-08-26"},
              {"method":"name","path":"/fixture/custom/run","name":"probe-agent","argv0":"run","expected":true,"evidence":"https://example.invalid/install","verifiedAt":"2026-08-26"},
              {"method":"collision","path":"/fixture/probe-agent-helper/run","name":"probe-agent-helper","argv0":"run","expected":false,"evidence":"https://example.invalid/process-model","verifiedAt":"2026-08-26"}
            ]
          },
          "source":{"kind":"none","path":""}
        }
        """#.utf8)
        let descriptor = try HarnessDocument.decode(data).descriptor

        let report = HarnessInstallationEvaluator.evaluate(descriptor)
        #expect(report.passed == 4)
        #expect(report.failures.isEmpty)
    }

    @Test("The SDK round-trips installation evaluations")
    func sdkOwnsInstallationProbeSchema() throws {
        let probe = HarnessConfig.ProcessRule.InstallationProbe(
            method: "curl",
            path: "/fixture/home/.local/bin/future-agent",
            name: "future-agent",
            argv0: "future-agent",
            expected: true,
            evidence: "https://future.example/install",
            verifiedAt: "2026-08-26")
        let config = HarnessConfig(
            id: "future", name: "Future",
            process: .init(names: ["future-agent"], installationProbes: [probe]),
            source: .init(kind: .none, path: ""))

        let encoded = try config.encoded()
        let process = try #require((JSONSerialization.jsonObject(with: encoded)
            as? [String: Any])?["process"] as? [String: Any])
        #expect((process["installationProbes"] as? [[String: Any]])?.count == 1)
        let descriptor = try HarnessDocument.decode(encoded).descriptor
        #expect(descriptor.processRule.installationProbes?.first?.method == "curl")
    }

    @Test("The SDK rejects installation claims without valid evidence metadata")
    func sdkRejectsInvalidProbeEvidence() {
        let probe = HarnessConfig.ProcessRule.InstallationProbe(
            method: "curl", path: "/fixture/tool", name: "tool", argv0: "tool",
            expected: true, evidence: "http://private.example/install",
            verifiedAt: "not-a-date")
        let config = HarnessConfig(
            id: "invalid", name: "Invalid",
            process: .init(names: ["tool"], installationProbes: [probe]),
            source: .init(kind: .none, path: ""))

        #expect(throws: HarnessConfig.ValidationError.self) {
            _ = try config.encoded()
        }
    }

    @Test("Probe schema typos fail harness checking")
    func checkerRejectsUnknownProbeFields() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(#"""
        {
          "formatVersion":1,"id":"bad-probe","name":"Bad Probe",
          "process":{"installationProbes":[
            {"methd":"curl","path":"/fixture/tool","name":"tool","argv0":"tool","expected":true,"evidence":"https://example.invalid","verifiedAt":"2026-08-26"}
          ]},
          "source":{"kind":"none","path":""}
        }
        """#.utf8)) as? [String: Any])

        #expect(HarnessCheck.schemaProblems(in: object).contains {
            $0.contains("process.installationProbes[0].methd")
                && $0.contains("method")
        })
    }

    private func validDay(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

private extension Optional where Wrapped == [String] {
    var orEmpty: [String] { self ?? [] }
}

private extension Optional where Wrapped == [HarnessDescriptor.ProcessRule.InstallationProbe] {
    var orEmpty: [HarnessDescriptor.ProcessRule.InstallationProbe] { self ?? [] }
}
