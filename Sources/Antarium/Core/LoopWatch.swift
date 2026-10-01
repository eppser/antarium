import Foundation

/// Whether an agent is running on a loop.
///
/// This was once written off as undetectable, on the grounds that a scheduled
/// wakeup lives only in the running process's memory and that inferring one
/// from a busy/idle cadence would be guesswork. The first half was wrong: an
/// agent that schedules a wakeup *records the call it made*, timestamp, delay
/// and all, in its own transcript. So this reads a declaration rather than
/// guessing from behaviour.
///
/// The second half held up under measurement. Across real sessions the gaps
/// between turns in a looping agent (median 11.5s, variability 3.93) are
/// indistinguishable from an idle one (19.4s, 4.15) — cadence carries no
/// signal, so none is used.
enum LoopWatch {

    /// How long past its due time a wakeup can be before the loop is treated as
    /// dead rather than late.
    ///
    /// A live loop is always a little overdue — the agent is mid-iteration when
    /// we look. A dead one is *hours* overdue: a session interrupted three days
    /// ago still had a wakeup pending, and calling that "looping" would be a
    /// standing lie about an agent that will never move again.
    static let grace: TimeInterval = 3600

    static func isLooping(wakeAt: Date?, stopped: Bool, now: Date = Date()) -> Bool {
        guard !stopped, let wakeAt else { return false }
        return now.timeIntervalSince(wakeAt) < grace
    }

    /// Some harnesses state the fact without a time. Codex keeps a goal per
    /// thread whose status is `active` until it finishes, pauses, or runs out
    /// of budget — that *is* the loop, and there is no next-wake to read.
    static func isLooping(declared: String?, wakeAt: Date?, stopped: Bool,
                          now: Date = Date()) -> Bool {
        if declared != nil { return true }
        return isLooping(wakeAt: wakeAt, stopped: stopped, now: now)
    }

    /// "loops in 12m", or "looping" once it is due and the agent is working.
    static func describe(declared: String?, wakeAt: Date?, stopped: Bool,
                         now: Date = Date()) -> String? {
        if let declared { return declared }
        return describe(wakeAt: wakeAt, stopped: stopped, now: now)
    }

    static func describe(wakeAt: Date?, stopped: Bool, now: Date = Date()) -> String? {
        guard isLooping(wakeAt: wakeAt, stopped: stopped, now: now), let wakeAt else { return nil }
        let seconds = wakeAt.timeIntervalSince(now)
        guard seconds > 30 else { return "looping" }
        // The unit is chosen after rounding, not before. Choosing it first
        // and rounding second says "loops in 60m" for anything from 59½
        // minutes up — a whole half-minute band where the row reads as a
        // number no clock shows.
        let minutes = Int((seconds / 60).rounded())
        if seconds < 3600, minutes < 60 { return "loops in \(minutes)m" }
        return "loops in \(Int((seconds / 3600).rounded()))h"
    }
}
