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

    /// Whether work begun at `generation` may still commit what it found.
    ///
    /// Both halves matter and they are not the same question: a scan can be
    /// superseded without being cancelled — a forced refresh replaces the
    /// generation, and the old task keeps running to completion — and it can
    /// be cancelled while still current, when the store is stopped. Either
    /// one means its rows are not to be published.
    ///
    /// Named here because four call sites asked it, and four copies of a
    /// two-part condition is three chances for one of them to lose a half.
    func mayPublish(_ generation: Int, cancelled: Bool) -> Bool {
        isCurrent(generation) && !cancelled
    }

    /// Counter wraparound has no catalogue entry: `latest` is private and
    /// starts at zero, so no test can reach the value where `&+=` and `+=`
    /// differ.
    ///
    /// Counter wraparound is the one case where a stale generation could
    /// compare equal to a live one. `begin()` uses wrapping addition so it
    /// cannot trap, and at one scan every five seconds reaching Int.max takes
    /// longer than the machine will exist — but the arithmetic is stated
    /// rather than assumed.
    var current: Int { latest }
}
