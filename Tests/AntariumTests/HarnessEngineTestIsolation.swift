import Foundation

/// HarnessEngine intentionally owns a process-wide cache. Tests that assert cache
/// transitions must not run alongside another suite that resets that same cache.
enum HarnessEngineTestIsolation {
    static let lock = NSRecursiveLock()
}
