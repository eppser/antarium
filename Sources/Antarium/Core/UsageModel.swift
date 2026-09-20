import Foundation

/// How urgent a gauge is. Three steps, not five — a menu bar is not the place
/// for a gradient, and green/amber/red is legible at a glance.
enum Severity: Int, Comparable {
    case normal = 0, low = 1, critical = 2
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    static func forRemaining(_ remaining: Double) -> Severity {
        // A fully consumed window is always critical — the tolerance catches
        // a limit reported as 99.97% that would otherwise round to "100%" in
        // the text while still colouring as merely low.
        if remaining <= 0.005 { return .critical }
        switch remaining {
        case ..<0.15: return .critical
        case ..<0.40: return .low
        default:      return .normal
        }
    }
}

/// One limit window: a 5-hour session, a rolling week, a credit balance.
struct Gauge: Equatable {
    let id: String
    /// Two characters, drawn in the menu bar. "5H", "7D", "BAL".
    let badge: String
    /// Full name for the dropdown.
    let title: String
    /// 0...1 consumed.
    let used: Double
    let resetsAt: Date?
    let reportedSeverity: Severity
    /// Length of the window in seconds, when the provider reports it. Used to
    /// order rows shortest-first rather than trusting the response's ordering.
    var windowSeconds: Double? = nil
    /// A figure with no denominator: a credit balance, where the service says
    /// what is left but never what a full tank was.
    ///
    /// These cannot honestly be a bar. Pinning such a gauge to 100% — what a
    /// balance-only provider has to do to fit a percentage model — paints the
    /// same full green meter whether $500 or two cents remain, which is worse
    /// than showing no meter at all. So a gauge carrying an amount draws its
    /// figure and no bar.
    var amount: Amount? = nil

    struct Amount: Equatable {
        let value: Double
        /// ISO 4217 where the service states one. Kept as given rather than
        /// assumed: DeepSeek bills Chinese accounts in CNY and calling that
        /// "$" would misreport the balance by an exchange rate.
        let currency: String
    }

    /// True when this gauge has a denominator and can be drawn as a meter.
    var hasMeter: Bool { amount == nil }

    var remaining: Double { min(max(1 - used, 0), 1) }
    /// A balance has no headroom to judge, so it never colours itself urgent
    /// off its own figure — only a severity the provider actually reported.
    var severity: Severity {
        hasMeter ? max(reportedSeverity, Severity.forRemaining(remaining)) : reportedSeverity
    }

    /// The balance, formatted for a menu bar: no decimals once it is large
    /// enough that they are noise, two below that so a nearly-empty account
    /// does not read as a round zero.
    var amountText: String? {
        guard let amount else { return nil }
        let magnitude = abs(amount.value)
        let digits = magnitude >= 100 ? 0 : 2
        let number = String(format: "%.\(digits)f", amount.value)
        return Gauge.symbol(for: amount.currency).map { $0 + number }
            ?? "\(number) \(amount.currency)"
    }

    /// Only the symbols that are unambiguous. Anything else keeps its code,
    /// because a wrong symbol is a wrong number.
    static func symbol(for currency: String) -> String? {
        switch currency.uppercased() {
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        default:    return nil
        }
    }

    /// Rounded so a nonzero sliver never reads as a flat 0%.
    var remainingPercentText: String { Gauge.percentText(remaining) }
    var usedPercentText: String { Gauge.percentText(min(max(used, 0), 1)) }

    static func percentText(_ fraction: Double) -> String {
        let p = fraction * 100
        if p > 0 && p < 1 { return "<1%" }
        if p < 100 && p > 99 { return ">99%" }
        return "\(Int(p.rounded()))%"
    }
}

/// A complete reading from one agent.
struct Snapshot: Equatable {
    let providerID: String
    /// The windows worth watching. The menu bar draws the first two; the
    /// dropdown lists all of them. Providers with only one meaningful window
    /// return one, and the bar renders a single row.
    let gauges: [Gauge]
    /// Listed in the dropdown only (per-model caps and the like).
    let extras: [Gauge]
    /// e.g. "max plan".
    let accountLabel: String?
    let fetchedAt: Date

}

enum ProviderError: LocalizedError, Equatable {
    /// The agent isn't installed, or has never been signed in here.
    case notConfigured(String)
    /// Credentials exist but are stale.
    case needsAuth(String)
    /// Credentials exist but macOS won't let us read them.
    case accessDenied(String)
    case transport(String)
    case badResponse(String)
    /// We can reach the agent but it exposes no usage figures we can trust.
    case unsupported(String)

    /// Whether signing in again is a plausible fix. A missing or rejected
    /// credential, yes. A network failure or an unparseable response is not the
    /// user's to fix, and offering a login for it would just waste their time.
    var suggestsSignIn: Bool {
        switch self {
        case .needsAuth, .notConfigured: return true
        case .accessDenied, .transport, .badResponse, .unsupported: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m), .needsAuth(let m), .accessDenied(let m),
             .transport(let m), .badResponse(let m), .unsupported(let m): return m
        }
    }

    /// Shown in the menu bar when there is no reading at all.
    var badge: String {
        switch self {
        case .notConfigured: return "set up"
        case .needsAuth:     return "sign in"
        case .accessDenied:  return "keychain"
        case .transport:     return "offline"
        case .badResponse:   return "error"
        case .unsupported:   return "n/a"
        }
    }
}

extension Gauge {
    /// A short, upper-case tag for a window: the whole name when it is already
    /// short enough to read as one, otherwise its first three letters.
    /// Both providers derived this the same way; the rule belongs with the
    /// type that displays it.
    static func badge(from name: String) -> String {
        name.count <= 4 ? name.uppercased() : String(name.prefix(3)).uppercased()
    }
}
