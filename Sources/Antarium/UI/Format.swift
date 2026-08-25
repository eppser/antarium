import Foundation

enum Format {
    /// Ultra-compact countdown for the menu bar: "47m", "4h", "3d".
    static func shortCountdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "now" }
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    /// Roomier phrasing for the dropdown: "resets in 4h 12m · today 09:50".
    static func longReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "no scheduled reset" }
        let s = date.timeIntervalSince(now)
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
        let s = max(0, now.timeIntervalSince(date))
        if s < 45 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
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
