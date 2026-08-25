/// Monotonic publication gate for scans. Cancellation is cooperative, so an
/// older filesystem scan may still finish after a forced replacement; only the
/// newest generation is allowed to commit its rows.
struct ScanGeneration {
    private var latest = 0

    mutating func begin() -> Int {
        latest &+= 1
        return latest
    }

    func isCurrent(_ generation: Int) -> Bool {
        generation == latest
    }
}
