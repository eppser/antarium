import Foundation

enum Format {
    /// The longest interval this app will put a number on.
    ///
    /// The same bound `FieldPath.epoch` puts on a decoded timestamp — the end
    /// of year 9999 — so an interval these formatters would refuse is exactly
    /// one the decoder would have refused first.
    static let maxInterval: TimeInterval = 253_402_300_799

    /// Whether an interval can be turned into a figure at all.
    ///
    /// Every branch below ends in `Int(seconds / unit)`, and `Int(Double)`
    /// traps rather than rounds: a NaN, an infinity, or a magnitude past
    /// `Int.max` takes the app down instead of printing something wrong.
    /// Confirmed in isolation — SIGTRAP for `.nan`, `.infinity` and 1e300 —
    /// and this class has done it here before, when a harness reporting a
    /// negative context against a small window took the menu bar down.
    ///
    /// Nothing reaches these with such an interval today. Numeric timestamps
    /// go through `FieldPath.epoch`, which bounds them; string ones go
    /// through a grammar with a four-digit year; process and filesystem times
    /// come from the kernel. That is six producers agreeing, and the guard
    /// belongs next to the arithmetic rather than next to each of them — the
    /// seventh will be a mapping somebody adds, and a crash in the menu bar
    /// takes the whole app with it.
    ///
    /// An interval that fails this is unknown, not zero and not never: the
    /// callers say so rather than printing a figure they cannot stand behind.
    ///
    /// `isFinite` has no catalogue entry, because removing it changes no
    /// answer: `abs(.nan) <= x` and `abs(.infinity) <= x` are both false, so
    /// the magnitude test already refuses them. Kept because it says what is
    /// meant, and because the magnitude test is a comparison somebody may
    /// rewrite — the same reason `age` keeps a clamp it does not need.
    static func canDisplay(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && abs(seconds) <= maxInterval
    }

    /// Ultra-compact countdown for the menu bar: "47m", "4h", "3d".
    static func shortCountdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = date.timeIntervalSince(now)
        guard canDisplay(s) else { return "—" }
        if s <= 0 { return "now" }
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    /// Roomier phrasing for the dropdown: "resets in 4h 12m · today 09:50".
    static func longReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "no scheduled reset" }
        let s = date.timeIntervalSince(now)
        guard canDisplay(s) else { return "reset time unknown" }
        guard s > 0 else { return "resetting now" }

        var span: String
        if s < 3600 {
            span = "\(max(1, Int(s / 60)))m"
        } else if s < 86_400 {
            let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            span = m > 0 ? "\(h)h \(m)m" : "\(h)h"
        } else {
            let d = Int(s / 86_400), h = Int(s.truncatingRemainder(dividingBy: 86_400) / 3600)
            span = h > 0 ? "\(d)d \(h)h" : "\(d)d"
        }
        return "resets in \(span) · \(clock.string(from: date))"
    }

    /// "just now", "3 min ago", "2 h ago".
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        // The clamp has no catalogue entry: every negative interval is
        // already caught by the "just now" branch below, so removing it
        // changes no answer. Kept because it states the intent, and because
        // the branch below is a threshold somebody may move.
        let s = max(0, now.timeIntervalSince(date))
        // "unknown" rather than "never": no activity recorded and an activity
        // time that cannot be read are different things, and the row that
        // shows this is the one a user checks to see whether an agent is
        // still going.
        guard canDisplay(s) else { return "unknown" }
        if s < 45 { return "just now" }
        // `max(1, …)` for the same reason `shortCountdown` has it, which is
        // the sibling that already did: between forty-five seconds and a
        // minute the division truncates to nought, and a row reading "0 min
        // ago" looks broken rather than recent.
        if s < 3600 { return "\(max(1, Int(s / 60))) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86_400)) d ago"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
