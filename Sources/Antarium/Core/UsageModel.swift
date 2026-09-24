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
    /// A last bound on text that reaches a menu item.
    ///
    /// Deliberately far above anything anyone would write. It is not the
    /// policy — `DescriptorProvider.maxResponseText` clamps network text to
    /// 64 because a response is input, and a descriptor's own labels are left
    /// exactly as their author wrote them because local configuration is
    /// trusted. This sits underneath both and exists for the case neither
    /// covers: a provider that forgets, and a body the 2 MiB cap admits.
    /// Two megabytes is not a menu item at any level of trust.
    ///
    /// Setting it near a plausible title would quietly overrule the author,
    /// which is why it is not near one.
    static let maxTitle = 4_096
    /// A badge is two or three characters — the longest thing any shipped
    /// harness puts near one is eleven. Beyond that is a misread field.
    static let maxBadge = 64
    /// A currency code, not a sentence. ISO 4217 is three letters; eight
    /// leaves room for the informal ones a service might send instead.
    static let maxCurrency = 8
    /// Above this a figure is printed in scientific notation rather than in
    /// full. Not a rejection — the number is still the number, and refusing
    /// it would make `hasMeter` true and draw a bar where there is no
    /// denominator, which is a figure invented out of a broken one. This only
    /// stops a balance being three hundred digits of menu bar.
    static let plainAmountLimit = 1e12

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

    /// Written out so the clamp cannot be bypassed by constructing one.
    /// The parameter list matches the memberwise initialiser it replaces.
    init(id: String, badge: String, title: String, used: Double,
         resetsAt: Date? = nil, reportedSeverity: Severity = .normal,
         windowSeconds: Double? = nil, amount: Amount? = nil) {
        self.id = Gauge.clamp(id, to: Gauge.maxTitle)
        self.badge = Gauge.clamp(badge, to: Gauge.maxBadge)
        self.title = Gauge.clamp(title, to: Gauge.maxTitle)
        // A provider that computes a fraction from two response numbers can
        // divide by zero. NaN compares false against everything, so it would
        // pass every bound check below and paint an empty meter that never
        // moves; infinity would paint a full one.
        //
        // Clamped as well as checked, so the range this field documents is
        // true by construction rather than by every provider remembering.
        // They all do clamp today — but the value is multiplied by a hundred
        // and converted to an `Int` downstream, and `Int` conversion traps
        // rather than rounds on a large enough figure. One forgetful mapping
        // would have been a crash, and the invariant is one line.
        self.used = Gauge.fraction(used)
        self.resetsAt = resetsAt
        self.reportedSeverity = reportedSeverity
        self.windowSeconds = (windowSeconds?.isFinite == true) ? windowSeconds : nil
        // The amount was the one field here that was taken as given, in an
        // initialiser whose whole argument is that the range each field
        // documents should be true by construction. Its currency is vendor
        // text — clamped to sixty-four characters on the way out of a
        // provider, which is a sentence, not a currency code — and its value
        // is only checked for being finite. Both are drawn in the menu bar,
        // which is shared with every other application's status item and has
        // one screen's width for all of them. A sixty-four character currency
        // made this item 540 points wide and a balance of 1e300 made it 1,993.
        self.amount = amount.map {
            Amount(value: $0.value.isFinite ? $0.value : 0,
                   currency: Gauge.clamp($0.currency, to: Gauge.maxCurrency))
        }
    }

    static func clamp(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }

    struct Amount: Equatable {
        let value: Double
        /// ISO 4217 where the service states one. Kept as given rather than
        /// assumed: DeepSeek bills Chinese accounts in CNY and calling that
        /// "$" would misreport the balance by an exchange rate.
        let currency: String
    }

    /// True when this gauge has a denominator and can be drawn as a meter.
    var hasMeter: Bool { amount == nil }

    var remaining: Double { Gauge.fraction(1 - used) }
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
        let number: String
        if magnitude >= Gauge.plainAmountLimit {
            // Scientific rather than truncated: a shortened number is a
            // different number, and this one is still exactly what was
            // reported — just not three hundred digits of it.
            number = String(format: "%.3g", amount.value)
        } else {
            number = String(format: "%.\(magnitude >= 100 ? 0 : 2)f", amount.value)
        }
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
    var usedPercentText: String { Gauge.percentText(used) }

    /// A fraction reduced to the nought-to-one range this type documents.
    ///
    /// Written once because it was written three times — in the initialiser,
    /// in `remaining`, and again at the one call site of `percentText` that
    /// went through a gauge. The one that did not go through a gauge had no
    /// clamp at all, which is the shape this kind of bug takes: the guard
    /// lives next to one caller rather than next to the arithmetic it
    /// protects, and the next caller does not know to repeat it.
    static func fraction(_ value: Double) -> Double {
        value.isFinite ? Swift.min(Swift.max(value, 0), 1) : 0
    }

    /// Clamps rather than trusting its argument, because the last line
    /// converts to `Int` — which traps rather than rounds on a NaN, an
    /// infinity, or anything past `Int.max`. Nothing reaches it with such a
    /// figure today: gauges clamp on the way in and the settings preview
    /// passes its own literals. But this is `static`, it takes a bare
    /// `Double`, and a provider that divides two response numbers can produce
    /// all three of those. A crash in the menu bar takes the whole app with
    /// it, and the guard is the same line the initialiser already runs.
    static func percentText(_ fraction: Double) -> String {
        let p = Gauge.fraction(fraction) * 100
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

    /// What to tell the user underneath the message, given what this agent's
    /// own setup instructions are.
    ///
    /// Beside `suggestsSignIn` because the two had drifted: the rule above
    /// says an unparseable or unsupported answer is not the user's to fix and
    /// that offering a login for it wastes their time, and the menu offered
    /// one anyway. A free Cursor account with no plan, or a 404 from a host
    /// that moved its endpoint, was told to sign in to Cursor again. Asking
    /// the rule rather than re-listing the cases is what keeps them together.
    func hint(setupHint: String) -> String {
        if suggestsSignIn { return setupHint }
        switch self {
        case .accessDenied:
            return "Open Keychain Access, select the agent's credential item, "
                 + "and allow Antarium under Access Control."
        case .transport:
            return "Will retry automatically."
        case .badResponse:
            return "The usage API returned something unexpected."
        case .unsupported:
            return "This account reports no usage figures this app can chart. "
                 + "Signing in again will not change it."
        case .needsAuth, .notConfigured:
            // Unreachable: both suggest signing in, so the guard above has
            // already returned. Written out because Swift wants the switch
            // exhaustive and because a new case should be a decision rather
            // than a fallthrough — and noted as inert, since it makes the
            // guard redundant: removing that guard leaves this returning the
            // same answer, so no mutation of it can be caught. The guard
            // stays because it is what ties this to `suggestsSignIn`; this
            // arm would tie it to nothing.
            return setupHint
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
