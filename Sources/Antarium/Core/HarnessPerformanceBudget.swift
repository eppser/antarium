import Foundation

/// Stable CI guardrails, intentionally generous across supported Macs.
/// Exact work counts catch algorithmic regressions; elapsed time catches only
/// catastrophic slowdowns and is not presented as a product benchmark.
enum HarnessPerformanceBudget {
    static let coldJSONLMilliseconds = 5_000.0

    /// What a full scan may take, measured at steady state.
    ///
    /// Deliberately far above what any healthy machine shows — this app was
    /// rebuilt because a scan was costing 54% of a core sustained, and what
    /// is worth catching automatically is that shape of failure rather than a
    /// third slower on a busy laptop. `verify.sh` printed the numbers and
    /// gated on nothing, so a scan that became ten times slower would have
    /// been reported underneath "All checks passed".
    static let scanMilliseconds = 5_000.0

    /// Whether a benchmark run says anything about steady state.
    ///
    /// A machine still absorbing transcript history is measuring catch-up
    /// throughput, which is legitimately slower and varies with whatever the
    /// developer happens to have been running. Gating on that number would
    /// fail for a reason nobody could act on, so it is not gated — and the
    /// run says which of the two it was rather than leaving it to be guessed.
    static func scanIsAcceptable(fastestMilliseconds: Double,
                                 backlogged: Int,
                                 budget: Double = scanMilliseconds) -> Bool {
        verdict(fastestMilliseconds: fastestMilliseconds,
                backlogged: backlogged, budget: budget) != .over
    }

    /// What a benchmark run established, which is not always pass or fail.
    enum Verdict: Equatable { case within, over, inconclusive }

    /// The three answers a run can give.
    ///
    /// Skipping the whole gate whenever a backlog existed threw away the half
    /// of it that is still sound. A pass that was absorbing transcript
    /// history did strictly more work than a steady-state pass does — the
    /// same scan, plus up to a read budget per transcript — so finishing
    /// under the budget anyway is evidence about steady state as well, and
    /// that is the case nearly every run is in. Only the other direction
    /// cannot be concluded: an over-budget run that was still catching up
    /// might be perfectly fast once it has.
    ///
    /// Those three transcripts on this machine are each larger than every
    /// warm-up pass put together, so "drain, then measure" alone left the
    /// gate unreachable here however many passes it was given.
    static func verdict(fastestMilliseconds: Double, backlogged: Int,
                        budget: Double = scanMilliseconds) -> Verdict {
        // No `isFinite` guard: a NaN or an infinity already compares false
        // against the budget, so one would be a line nothing could catch.
        if fastestMilliseconds <= budget { return .within }
        return backlogged == 0 ? .over : .inconclusive
    }

    /// How many passes may be spent absorbing transcript history before the
    /// measured ones.
    ///
    /// Each pass reads a bounded chunk of every transcript, so a backlog
    /// drains over a few of them rather than in one. Bounded because a
    /// transcript being appended to as fast as it is read never drains, and a
    /// benchmark that never finishes is worse than one that says it could not
    /// measure.
    static let maxWarmupPasses = 5

    /// Whether another warm-up pass is worth running before the clock starts.
    ///
    /// Without this the gate was unreachable on any machine carrying a
    /// backlog: `scanIsAcceptable` returns true whenever one exists, so a scan
    /// ten times slower than its budget was reported underneath "All checks
    /// passed" — the failure this budget was written to catch, surviving in
    /// the one state most developer Macs are actually in.
    ///
    /// Pure, so the drain policy is testable without running a benchmark.
    static func needsWarmup(backlogged: Int, passesRun: Int,
                            limit: Int = maxWarmupPasses) -> Bool {
        backlogged > 0 && passesRun < limit
    }

    /// Which of a run's passes the budget is about.
    ///
    /// The fastest, because the first is cold — it builds the caches the
    /// others read — and the budget is a statement about steady state.
    /// Gating on the last pass instead would be gating on whatever the
    /// machine happened to be doing during it.
    ///
    /// Separated so that choice is checkable: measured inside the benchmark
    /// loop it was reachable only by running the benchmark, which the test
    /// suite does not.
    static func steadyState(_ passes: [Double]) -> Double {
        passes.min() ?? .infinity
    }
}
