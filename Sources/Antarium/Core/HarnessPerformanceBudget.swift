import Foundation

/// Stable CI guardrails, intentionally generous across supported Macs.
/// Exact work counts catch algorithmic regressions; elapsed time catches only
/// catastrophic slowdowns and is not presented as a product benchmark.
enum HarnessPerformanceBudget {
    static let coldJSONLMilliseconds = 5_000.0
}
