import Foundation
import Testing
@testable import Antarium

/// The sparkline beside every row. Reversed, it still looks like a sparkline
/// — a busy session reads as one winding down and nothing anywhere says
/// otherwise, which is why the order needs a test rather than a look.
@Suite("The activity sparkline covers the window it claims")
struct ActivitySeriesTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var newest: Int { 1_800_000_000 / TranscriptStats.bucketSeconds }
    private var count: Int { TranscriptStats.historyHours * 3600 / TranscriptStats.bucketSeconds }

    @Test("It is always the full window, however little is in it")
    func lengthIsFixed() {
        #expect(TranscriptStats.series(from: [:], now: now).count == count)
        #expect(TranscriptStats.series(from: [newest: 5], now: now).count == count)
        #expect(TranscriptStats.series(from: [:], now: now).allSatisfy { $0 == 0 })
    }

    @Test("The newest bucket is last, not first")
    func newestIsLast() {
        let series = TranscriptStats.series(from: [newest: 7], now: now)
        #expect(series.last == 7, "the current ten minutes belong at the right-hand end")
        #expect(series.first == 0)
    }

    @Test("The oldest bucket in the window is first")
    func oldestIsFirst() {
        let series = TranscriptStats.series(from: [newest - (count - 1): 3], now: now)
        #expect(series.first == 3)
        #expect(series.last == 0)
    }

    @Test("Buckets land in the order they happened")
    func orderIsChronological() {
        let series = TranscriptStats.series(
            from: [newest: 3, newest - 1: 2, newest - 2: 1], now: now)
        #expect(Array(series.suffix(3)) == [1, 2, 3])
    }

    @Test("Anything older than the window is not shown")
    func beyondTheWindowIsDropped() {
        let series = TranscriptStats.series(from: [newest - count: 9], now: now)
        #expect(series.allSatisfy { $0 == 0 }, "a bucket outside the window appeared inside it")
    }

    /// A trace whose timestamps are ahead of this machine's clock — skew, or
    /// a file written elsewhere — must not push the window forward.
    @Test("A bucket in the future is not shown")
    func futureBucketsAreDropped() {
        let series = TranscriptStats.series(from: [newest + 1: 9, newest + 50: 9], now: now)
        #expect(series.allSatisfy { $0 == 0 })
    }

    @Test("A clock that cannot be read yields an empty window, not a crash")
    func unreadableClock() {
        for bad in [Date(timeIntervalSince1970: .infinity),
                    Date(timeIntervalSince1970: .nan),
                    Date(timeIntervalSince1970: 1e300)] {
            let series = TranscriptStats.series(from: [newest: 5], now: bad)
            #expect(series.count == count)
            #expect(series.allSatisfy { $0 == 0 })
        }
    }

    /// Buckets are epoch arithmetic, so where the machine thinks it is must
    /// not move them. verify.sh runs the whole suite under a non-UTC zone for
    /// the same reason; this states it directly.
    @Test("The window does not move with the local time zone")
    func timeZoneIndependent() {
        // Bucket indices are epoch seconds divided by the bucket length, so
        // the same inputs must give the same series wherever the machine
        // thinks it is. Checked by computing the expected indices here from
        // the epoch directly, with no calendar anywhere in the arithmetic —
        // the obvious "improvement" to this function is to format buckets as
        // local times, and that is what would break it.
        let series = TranscriptStats.series(from: [newest: 4, newest - 5: 2], now: now)
        #expect(series.last == 4)
        #expect(series[count - 6] == 2)
        #expect(series.reduce(0, +) == 6, "nothing else picked up a value")
    }

    @Test("Every count survives the trip, including large ones")
    func countsAreNotClamped() {
        let series = TranscriptStats.series(from: [newest: Int.max], now: now)
        #expect(series.last == Int.max)
    }
}
