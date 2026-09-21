import Foundation

/// Amp (by Sourcegraph), from `amp usage --no-color`.
///
/// Native rather than a descriptor because the reply is text, not JSON, and
/// descriptors map field paths. Nothing else about it is hard: the CLI holds
/// the credential, so there is none here to expire, and a signed-out CLI
/// fails the command rather than returning a number nobody should trust.
///
/// Parsed by scanning rather than with a regular expression. The input is a
/// subprocess's stdout, which is bounded but not trusted, and a pattern with
/// backtracking in it is a way to turn a long line into a hung menu bar.
final class AmpProvider: UsageProvider, @unchecked Sendable {
    let id = "ampcode"
    let displayName = "Amp"
    var setupHint: String { "Run `amp` in Terminal and sign in." }
    let signInCommand: String? = "amp login"
    /// The shapes below come from Amp's own parsing fixtures; no live account
    /// has confirmed them here, and the row says so.
    let isVerified = false

    var isConfigured: Bool {
        // Cheap and synchronous: a PATH walk, never the command itself.
        ConfiguredProbe.value(id) { CommandPath.resolve("amp") != nil }
    }

    func fetch() async throws -> Snapshot {
        guard let path = CommandPath.resolve("amp") else {
            throw ProviderError.notConfigured("Amp isn't installed on this Mac.")
        }
        let result = Shell.execute(path, ["usage", "--no-color"],
                                   timeout: 15, outputLimit: 64 * 1_024)
        guard result.completeOutput else {
            throw ProviderError.badResponse("Amp's reply exceeded the output limit.")
        }
        guard result.exitCode == 0 else {
            throw ProviderError.needsAuth("Amp isn't signed in on this Mac.")
        }
        return try Self.makeSnapshot(result.stdout)
    }

    /// At most this many lines are considered, and each is read up to this
    /// length. Amp reports three lines; anything past that is not a report.
    static let maxLines = 64
    static let maxLineLength = 512

    /// Maps `amp usage` output onto gauges. Static and pure, so the shapes can
    /// be tested with nothing installed.
    ///
    /// Two line shapes carry figures:
    ///
    ///     Amp Free: $17.59/$20 remaining (replenishes +$0.83/hour) - https://…
    ///     Individual credits: $50 remaining - https://…
    ///
    /// The first has a cap and becomes a meter. The second does not and
    /// becomes a balance — the two answer different questions, and a balance
    /// charted as a meter needs a denominator that was never reported.
    ///
    /// The "Signed in as …" line is deliberately not read: it carries an
    /// email address, and nothing here needs one.
    static func makeSnapshot(_ text: String) throws -> Snapshot {
        var gauges: [Gauge] = []
        var balances: [Gauge] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(maxLines) {
            let line = String(raw.prefix(maxLineLength))
            guard line.contains("remaining"), let colon = line.firstIndex(of: ":") else { continue }
            let label = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.count <= 64 else { continue }
            let rest = line[line.index(after: colon)...]
            guard let (amount, total) = figures(in: rest) else { continue }

            let badge = String(label.prefix(3)).uppercased()
            if let total, total > 0 {
                gauges.append(Gauge(id: label, badge: badge, title: label,
                                    used: min(max(1 - amount / total, 0), 1),
                                    resetsAt: nil, reportedSeverity: .normal))
            } else if total == nil {
                balances.append(Gauge(id: label, badge: badge, title: label,
                                      used: 0, resetsAt: nil, reportedSeverity: .normal,
                                      amount: Gauge.Amount(value: amount, currency: "USD")))
            }
        }
        guard !gauges.isEmpty || !balances.isEmpty else {
            throw ProviderError.badResponse("Amp reported no readable usage line.")
        }
        // A meter is the headline; a bare balance goes to the dropdown, which
        // is where the descriptor providers put theirs too.
        return Snapshot(providerID: "ampcode",
                        gauges: gauges.isEmpty ? balances : gauges,
                        extras: gauges.isEmpty ? [] : balances,
                        accountLabel: nil, fetchedAt: Date())
    }

    /// `$17.59/$20` → (17.59, 20); `$50` → (50, nil); anything else → nil.
    ///
    /// Scanned rather than matched. Only the first `$` is considered, so a
    /// price quoted later in the line — the hourly replenishment rate, for
    /// one — cannot be mistaken for the figure.
    private static func figures(in text: Substring) -> (Double, Double?)? {
        guard let start = text.firstIndex(of: "$") else { return nil }
        var index = text.index(after: start)
        guard let first = number(in: text, from: &index) else { return nil }
        guard index < text.endIndex, text[index] == "/" else { return (first, nil) }
        index = text.index(after: index)
        guard index < text.endIndex, text[index] == "$" else { return nil }
        index = text.index(after: index)
        guard let second = number(in: text, from: &index) else { return nil }
        return (first, second)
    }

    /// One decimal, consumed in place. Rejects anything that is not finite, so
    /// a line of digits cannot become an infinite balance.
    private static func number(in text: Substring, from index: inout Substring.Index) -> Double? {
        let start = index
        var seenDot = false
        while index < text.endIndex {
            let c = text[index]
            if c.isNumber { index = text.index(after: index) }
            else if c == ".", !seenDot { seenDot = true; index = text.index(after: index) }
            else { break }
        }
        guard start < index, let value = Double(text[start..<index]), value.isFinite
        else { return nil }
        return value
    }
}
