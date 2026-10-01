import Foundation
import Testing
@testable import Antarium

/// Turning an interval into "4h 12m", "3 d ago", "47m".
///
/// Every branch of every one of these ends in `Int(seconds / unit)`, and
/// `Int(Double)` traps rather than rounds. An interval that is not a number,
/// or is larger than `Int` can hold, is not a wrong string — it is the menu
/// bar taking the app down. The same class already did that here once, when
/// a harness reported a negative context against a small window.
///
/// No producer can currently deliver such an interval: numeric timestamps go
/// through `FieldPath.epoch`, string ones through a four-digit-year grammar,
/// process and filesystem times come from the kernel. That is the point —
/// the guard was spread across six producers and absent from the arithmetic.
@Suite("No interval makes a duration trap")
struct IntervalFormatTests {

    /// Intervals no decoder would pass on, asked of the formatters directly.
    static let impossible: [TimeInterval] = [
        .nan, .infinity, -.infinity, 1e300, -1e300, 1e20,
        .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
    ]

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A countdown to an unreadable time says nothing rather than crashing",
          arguments: impossible)
    func countdown(seconds: TimeInterval) {
        let text = Format.shortCountdown(to: now.addingTimeInterval(seconds), now: now)
        #expect(text == "—", Comment(rawValue: "\(seconds) produced \(text)"))
    }

    @Test("A reset at an unreadable time is unknown, not scheduled",
          arguments: impossible)
    func reset(seconds: TimeInterval) {
        let text = Format.longReset(now.addingTimeInterval(seconds), now: now)
        #expect(text == "reset time unknown", Comment(rawValue: "\(seconds) produced \(text)"))
    }

    /// `age` was already safe, by an accident worth writing down: it clamps
    /// with `max(0, …)` first, and that returns 0 for a NaN as well as for a
    /// negative interval — so an unreadable or future time reaches the "just
    /// now" branch rather than the arithmetic. Only a time far enough in the
    /// past survives the clamp, and that is the one the guard is for.
    @Test("An unreadable activity time never traps", arguments: impossible)
    func age(seconds: TimeInterval) {
        let text = Format.age(now.addingTimeInterval(seconds), now: now)
        #expect(["just now", "unknown"].contains(text),
                Comment(rawValue: "\(seconds) produced \(text)"))
    }

    /// The case the clamp does not catch: a past time too far back to count.
    @Test("An activity time too far back is unknown, not never",
          arguments: [1e300, 1e20, Double.greatestFiniteMagnitude])
    func distantPastActivity(seconds: TimeInterval) {
        let text = Format.age(now.addingTimeInterval(-seconds), now: now)
        #expect(text == "unknown", Comment(rawValue: "\(seconds) ago produced \(text)"))
        // Distinct from no activity at all, which is what "never" means.
        #expect(text != Format.age(nil))
    }

    @Test("An unreadable duration says nothing rather than crashing",
          arguments: impossible)
    func duration(seconds: TimeInterval) {
        let text = Fmt.duration(seconds)
        #expect(text == "—", Comment(rawValue: "\(seconds) produced \(text)"))
    }

    /// The bound is the decoder's bound, so nothing a timestamp decoder will
    /// accept is refused here.
    ///
    /// Asserted on what `epoch` returns rather than what it is given: it
    /// reads anything past the year 5138 as milliseconds, so a number above
    /// its stated ceiling is divided by a thousand and accepted as a much
    /// earlier date. The invariant that matters is that no date it hands
    /// back can reach the arithmetic these formatters do.
    @Test("No date the decoder accepts is refused by the formatters")
    func decoderBoundAgrees() {
        let from = Date(timeIntervalSince1970: 0)
        let inputs: [Double] = [1, 1e9, 1e11, 1.7e12, 2.5e17, 253_402_300_799,
                                253_402_300_800, 2.534e17]
        for input in inputs {
            guard let date = FieldPath.epoch(input) else { continue }
            #expect(Format.canDisplay(date.timeIntervalSince1970),
                    Comment(rawValue: "epoch(\(input)) is past what can be formatted"))
            #expect(Format.shortCountdown(to: date, now: from) != "—",
                    Comment(rawValue: "epoch(\(input)) formatted as nothing"))
            #expect(Format.age(from, now: date) != "unknown")
        }
        // And it does refuse a magnitude even the millisecond reading cannot
        // bring inside the range, so the two agree on an edge rather than
        // the formatters carrying the decoder.
        #expect(FieldPath.epoch(2.6e20) == nil)
        #expect(FieldPath.epoch(.infinity) == nil)
        #expect(FieldPath.epoch(.nan) == nil)
    }

    /// The guard must not have swallowed the ordinary answers, or every
    /// assertion above would be satisfied by a formatter that says "—" to
    /// everything.
    @Test("Ordinary intervals still read the way they did")
    func ordinaryIntervalsUnchanged() {
        #expect(Format.shortCountdown(to: now.addingTimeInterval(2_820), now: now) == "47m")
        #expect(Format.shortCountdown(to: now.addingTimeInterval(4 * 3600), now: now) == "4h")
        #expect(Format.shortCountdown(to: now.addingTimeInterval(3 * 86_400), now: now) == "3d")
        #expect(Format.shortCountdown(to: now.addingTimeInterval(-5), now: now) == "now")
        #expect(Format.shortCountdown(to: nil) == "—")

        #expect(Format.longReset(now.addingTimeInterval(4 * 3600 + 720), now: now)
                    .hasPrefix("resets in 4h 12m · "))
        #expect(Format.longReset(nil) == "no scheduled reset")

        #expect(Format.age(now.addingTimeInterval(-10), now: now) == "just now")
        #expect(Format.age(now.addingTimeInterval(-3 * 60), now: now) == "3 min ago")
        #expect(Format.age(now.addingTimeInterval(-2 * 3600), now: now) == "2 h ago")
        #expect(Format.age(nil) == "never")

        #expect(Fmt.duration(2_820) == "47m")
        #expect(Fmt.duration(3 * 86_400) == "3d")
    }
}
