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
        guard backlogged == 0 else { return true }
        // No `isFinite` guard: a NaN or an infinity already compares false
        // against the budget, so one would be a line nothing could catch.
        return fastestMilliseconds <= budget
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
