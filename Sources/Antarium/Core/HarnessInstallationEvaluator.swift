import Foundation

/// Executes configuration-owned installation examples through the production
/// process matcher. The examples are intentionally synthetic: this evaluator
/// proves recognition logic without downloading, installing, or launching an
/// agent, and behaves identically in CI and on a user's machine.
enum HarnessInstallationEvaluator {
    struct Report {
        let passed: Int
        let total: Int
        let failures: [String]
    }

    static func evaluate(_ descriptor: HarnessDescriptor) -> Report {
        let probes = descriptor.processRule.installationProbes ?? []
        var passed = 0
        var failures: [String] = []

        if !probes.contains(where: \.expected) {
            failures.append("no positive installation probe")
        }
        if !probes.contains(where: { !$0.expected }) {
            failures.append("no negative collision/helper probe")
        }

        for (index, probe) in probes.enumerated() {
            // The three provenance checks below are a backstop: a descriptor
            // carrying a probe without a method, an HTTPS evidence URL and a
            // yyyy-MM-dd date does not decode, so no mutation of them can be
            // caught. Kept because this evaluator is the layer that would
            // still be right if the decoder's rules were relaxed.
            let label = "probe \(index + 1) (\(probe.method))"
            if probe.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("\(label) has no installation method")
                continue
            }
            guard let evidence = URL(string: probe.evidence),
                  evidence.scheme == "https", evidence.host != nil else {
                failures.append("\(label) has no HTTPS evidence URL")
                continue
            }
            guard day(probe.verifiedAt) != nil else {
                failures.append("\(label) has invalid verifiedAt \(probe.verifiedAt)")
                continue
            }

            let process = Processes.Info(pid: Int32(index + 1), ppid: 0,
                                         path: probe.path, name: probe.name,
                                         argv0: probe.argv0, rss: 0)
            let actual = descriptor.claims(process)
            if actual == probe.expected {
                passed += 1
            } else {
                failures.append("\(label) expected \(probe.expected ? "match" : "no match")"
                    + " but production matcher returned \(actual ? "match" : "no match")")
            }
        }
        return Report(passed: passed, total: probes.count, failures: failures)
    }

    private static func day(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value),
              formatter.string(from: date) == value else { return nil }
        return date
    }
}
