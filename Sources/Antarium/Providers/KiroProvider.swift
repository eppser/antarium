import Foundation

/// AWS Kiro, from the `kiro-cli` interactive session's `/usage` report.
///
/// Native for the same reason Amp is: the reply is text. The CLI holds the
/// credential, so there is none here to expire.
///
/// Kiro reports what has been *used*, where Amp reports what is left. Getting
/// that backwards yields a gauge that is exactly wrong and entirely plausible,
/// which is most of what the tests here are for.
final class KiroProvider: UsageProvider, @unchecked Sendable {
    let id = "kiro"
    let displayName = "Kiro"
    var setupHint: String { "Install kiro-cli and sign in." }
    let signInCommand: String? = "kiro-cli login"
    let isVerified = false

    var isConfigured: Bool {
        ConfiguredProbe.value(id) { CommandPath.resolve("kiro-cli") != nil }
    }

    func fetch() async throws -> Snapshot {
        guard let path = CommandPath.resolve("kiro-cli") else {
            throw ProviderError.notConfigured("Kiro isn't installed on this Mac.")
        }
        // Interactive: it reads `/usage` and then has to be told to leave, or
        // it sits on the pipe until the timeout.
        let result = Shell.execute(path, [], timeout: 20, outputLimit: 64 * 1_024,
                                   input: "/usage\n/quit\n")
        guard result.completeOutput else {
            throw ProviderError.badResponse("Kiro's reply exceeded the output limit.")
        }
        return try Self.makeSnapshot(result.stdout, now: Date())
    }

    static let maxLines = 128
    static let maxLineLength = 512

    /// Maps the `/usage` report onto gauges. Static and pure, so the shapes
    /// can be tested with nothing installed.
    ///
    ///     Estimated Usage | resets on 03/01 | KIRO FREE
    ///     🎁 Bonus credits: 122.54/500 credits used, expires in 29 days
    ///     Credits (0.00 of 50 covered in plan)
    ///
    /// Both figures are amounts *used* against a cap.
    static func makeSnapshot(_ text: String, now: Date) throws -> Snapshot {
        let clean = stripANSI(text)
        var gauges: [Gauge] = []
        var resets: Date?

        for raw in clean.split(separator: "\n", omittingEmptySubsequences: true).prefix(maxLines) {
            let line = String(raw.prefix(maxLineLength))
            if resets == nil, let found = resetDate(in: line, now: now) { resets = found }

            // "<label>: <used>/<total> credits used"
            if let colon = line.firstIndex(of: ":"), line.contains("credits used") {
                let label = label(line[line.startIndex..<colon])
                if let label, let (used, total) = pair(in: line[line.index(after: colon)...],
                                                       separator: "/"), total > 0 {
                    gauges.append(meter(label, used: used, total: total))
                    continue
                }
            }
            // "Credits (<used> of <total> covered in plan)"
            if line.contains("covered in plan"), let open = line.firstIndex(of: "(") {
                let label = label(line[line.startIndex..<open]) ?? "Credits"
                if let (used, total) = pair(in: line[line.index(after: open)...],
                                            separator: " of "), total > 0 {
                    gauges.append(meter(label, used: used, total: total))
                }
            }
        }
        guard !gauges.isEmpty else {
            throw ProviderError.badResponse("Kiro reported no readable usage line.")
        }
        if let resets {
            gauges = gauges.map {
                Gauge(id: $0.id, badge: $0.badge, title: $0.title, used: $0.used,
                      resetsAt: resets, reportedSeverity: $0.reportedSeverity)
            }
        }
        return Snapshot(providerID: "kiro", gauges: gauges, extras: [],
                        accountLabel: nil, fetchedAt: Date())
    }

    private static func meter(_ label: String, used: Double, total: Double) -> Gauge {
        Gauge(id: label, badge: String(label.prefix(3)).uppercased(), title: label,
              used: min(max(used / total, 0), 1), resetsAt: nil, reportedSeverity: .normal)
    }

    private static func label(_ text: Substring) -> String? {
        // The bonus line is prefixed with an emoji; keep the words.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .drop { !$0.isLetter }
        let label = String(trimmed).trimmingCharacters(in: .whitespaces)
        return label.isEmpty || label.count > 64 ? nil : label
    }

    /// `resets on MM/DD` — the year is not stated, so the next occurrence is
    /// taken. Resolved in UTC rather than through the local calendar: the same
    /// report must give the same instant wherever it is read, and the suite
    /// runs under a non-UTC zone for exactly this kind of reason. A reset date
    /// is approximate either way; being off by a year would not be.
    static func resetDate(in line: String, now: Date) -> Date? {
        guard let marker = line.range(of: "resets on ") else { return nil }
        var index = marker.upperBound
        guard let month = digits(line, &index, count: 2), month >= 1, month <= 12,
              index < line.endIndex, line[index] == "/" else { return nil }
        index = line.index(after: index)
        guard let day = digits(line, &index, count: 2), day >= 1, day <= 31 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var parts = calendar.dateComponents([.year], from: now)
        parts.month = month; parts.day = day
        parts.hour = 0; parts.minute = 0; parts.second = 0
        guard let candidate = calendar.date(from: parts) else { return nil }
        if candidate > now { return candidate }
        parts.year = (parts.year ?? 0) + 1
        return calendar.date(from: parts)
    }

    private static func digits(_ text: String, _ index: inout String.Index, count: Int) -> Int? {
        var value = 0, seen = 0
        while seen < count, index < text.endIndex, text[index].isNumber {
            value = value * 10 + (text[index].wholeNumberValue ?? 0)
            index = text.index(after: index)
            seen += 1
        }
        return seen == count ? value : nil
    }

    /// Two decimals either side of a separator.
    private static func pair(in text: Substring, separator: String) -> (Double, Double)? {
        guard let split = text.range(of: separator) else { return nil }
        guard let first = number(String(text[text.startIndex..<split.lowerBound])),
              let second = number(String(text[split.upperBound...])) else { return nil }
        return (first, second)
    }

    /// The leading decimal in a fragment, ignoring anything after it.
    private static func number(_ text: String) -> Double? {
        let trimmed = text.drop { !$0.isNumber }
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let value = Double(digits), value.isFinite else { return nil }
        return value
    }

    /// Removes CSI sequences. The report is drawn with a progress bar and
    /// colour codes, and a colour code contains a `[` and digits, which is
    /// enough to confuse any of the scanning above.
    static func stripANSI(_ text: String) -> String {
        var out = String(); out.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\u{1B}" {
                index = text.index(after: index)
                if index < text.endIndex, text[index] == "[" {
                    index = text.index(after: index)
                    while index < text.endIndex, !text[index].isLetter {
                        index = text.index(after: index)
                    }
                    if index < text.endIndex { index = text.index(after: index) }
                }
                continue
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }
}
