import Foundation

/// Proves a descriptor's `quota` mapping without an account, a network
/// connection, or the agent installed.
///
/// Session mappings already have this: `HarnessCompatibility` replays a
/// synthetic transcript through the real engine. Quota mappings had nothing —
/// a `windows` block could name a field that no response contains and the only
/// way to find out was to sign in to that service and watch the bar stay empty.
/// Every field path here is exercised against a recorded response shape, so a
/// mapping is wrong at build time rather than on a stranger's Mac.
///
/// The recorded responses are synthetic by construction: shapes copied from
/// each vendor's published schema, with invented numbers. Nothing in
/// `Resources/quota-fixtures` comes from a real account.
enum QuotaFixture {

    /// What the mapping is expected to produce. Only the parts a user sees —
    /// the internal `Gauge` can gain fields without invalidating every fixture.
    struct Expectation: Decodable, Equatable {
        struct Row: Decodable, Equatable {
            let id: String
            let badge: String
            let title: String
            /// Percent consumed, 0...100.
            let usedPercent: Double
            var windowSeconds: Double?
            /// ISO 8601, compared to the second.
            var resetsAt: String?
        }
        var accountLabel: String?
        let gauges: [Row]
    }

    struct Report {
        let id: String
        let passed: Bool
        let detail: String
        let verifiedAt: String?
    }

    /// Percent comparison tolerance. Field paths either resolve or they do not;
    /// this only absorbs decimal representation, not a wrong mapping.
    static let tolerance = 0.005

    static func fixtureURL(for id: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: id, withExtension: "json", subdirectory: "quota-fixtures")
    }

    /// Nil when this descriptor declares no quota at all — not a failure, just
    /// nothing to check.
    static func verify(_ descriptor: HarnessDescriptor, in bundle: Bundle) -> Report? {
        guard descriptor.quota != nil else { return nil }
        guard let url = fixtureURL(for: descriptor.id, in: bundle) else {
            return Report(id: descriptor.id, passed: false,
                          detail: "no quota fixture — add Resources/quota-fixtures/\(descriptor.id).json",
                          verifiedAt: nil)
        }
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Report(id: descriptor.id, passed: false,
                          detail: "quota fixture unreadable", verifiedAt: nil)
        }
        let verifiedAt = document["verifiedAt"] as? String
        guard let response = document["response"] as? [String: Any] else {
            return Report(id: descriptor.id, passed: false,
                          detail: "quota fixture has no `response` object", verifiedAt: verifiedAt)
        }
        guard let expectedRaw = document["expected"],
              let expectedData = try? JSONSerialization.data(withJSONObject: expectedRaw),
              let expected = try? JSONDecoder().decode(Expectation.self, from: expectedData) else {
            return Report(id: descriptor.id, passed: false,
                          detail: "quota fixture has no readable `expected` block",
                          verifiedAt: verifiedAt)
        }
        guard let provider = DescriptorProvider(descriptor) else {
            return Report(id: descriptor.id, passed: false,
                          detail: "descriptor has a quota block the provider rejected",
                          verifiedAt: verifiedAt)
        }
        do {
            let snapshot = try provider.makeSnapshot(response)
            let problems = differences(expected: expected, actual: snapshot)
            return Report(id: descriptor.id, passed: problems.isEmpty,
                          detail: problems.isEmpty ? "quota fixture passed"
                                                   : problems.joined(separator: "; "),
                          verifiedAt: verifiedAt)
        } catch {
            return Report(id: descriptor.id, passed: false,
                          detail: "mapping threw: \(error.localizedDescription)",
                          verifiedAt: verifiedAt)
        }
    }

    /// Every mismatch, not just the first — a wrong `root` usually breaks every
    /// row at once, and one line per row says so plainly.
    static func differences(expected: Expectation, actual: Snapshot) -> [String] {
        var problems: [String] = []
        if expected.accountLabel != actual.accountLabel {
            problems.append("account label \(quoted(actual.accountLabel))"
                + " ≠ expected \(quoted(expected.accountLabel))")
        }
        guard expected.gauges.count == actual.gauges.count else {
            return problems + ["\(actual.gauges.count) gauges ≠ expected \(expected.gauges.count)"
                + " (got \(actual.gauges.map(\.id).joined(separator: ", ")))"]
        }
        for (index, row) in expected.gauges.enumerated() {
            let got = actual.gauges[index]
            if got.id != row.id { problems.append("gauge \(index) id \(got.id) ≠ \(row.id)") }
            if got.badge != row.badge { problems.append("\(row.id) badge \(got.badge) ≠ \(row.badge)") }
            if got.title != row.title { problems.append("\(row.id) title \(quoted(got.title)) ≠ \(quoted(row.title))") }
            if abs(got.used * 100 - row.usedPercent) > tolerance {
                problems.append("\(row.id) used \(got.used * 100)% ≠ \(row.usedPercent)%")
            }
            if !same(got.windowSeconds, row.windowSeconds) {
                problems.append("\(row.id) windowSeconds \(describe(got.windowSeconds))"
                    + " ≠ \(describe(row.windowSeconds))")
            }
            let resets = got.resetsAt.map(iso.string(from:))
            if resets != row.resetsAt {
                problems.append("\(row.id) resetsAt \(quoted(resets)) ≠ \(quoted(row.resetsAt))")
            }
        }
        return problems
    }

    private static func same(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) <= tolerance
        default: return false
        }
    }

    private static func describe(_ value: Double?) -> String {
        value.map { String($0) } ?? "absent"
    }

    private static func quoted(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "absent"
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
