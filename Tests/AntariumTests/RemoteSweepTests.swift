import Foundation
import Testing
@testable import Antarium

/// How a fleet is walked: which machines are asked, in what order, and what is
/// said about the ones that were not.
///
/// `scanSweep` takes its clock, its cancellation and its scanner as
/// parameters, so all of this is checkable with no SSH and no network. None
/// of it was checked. It is the part of the app that decides what a
/// twenty-machine fleet shows, and a wrong answer here is a machine quietly
/// missing from the list rather than an error anybody sees.
@Suite("Walking a fleet")
struct RemoteSweepTests {

    /// Records what was asked, and answers immediately.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var asked: [String] = []
        func scanner(_ host: String, _ stop: @Sendable () -> Bool) -> RemoteTmux.Result {
            lock.lock(); asked.append(host); lock.unlock()
            return RemoteTmux.Result(rows: [], issue: nil)
        }
        var seen: [String] { lock.lock(); defer { lock.unlock() }; return asked }
    }

    private func sweep(_ hosts: [String], startIndex: Int = 0,
                       duration: TimeInterval = 30,
                       maxConcurrent: Int = 1,
                       clock: @escaping @Sendable () -> TimeInterval = { 0 },
                       cancellation: @escaping @Sendable () -> Bool = { false })
        -> (RemoteTmux.Sweep, Recorder) {
        let recorder = Recorder()
        let result = RemoteTmux.scanSweep(
            hosts: hosts, startIndex: startIndex, duration: duration,
            maxConcurrent: maxConcurrent, clock: clock, cancellation: cancellation,
            scanner: { recorder.scanner($0, $1) })
        return (result, recorder)
    }

    // MARK: - Which hosts

    @Test("Blank and repeated entries are dropped, and order is kept")
    func hostsAreNormalized() {
        #expect(RemoteTmux.normalizedHosts(["  b ", "a", "b", "", "   ", "a"]) == ["b", "a"])
        #expect(RemoteTmux.normalizedHosts([]).isEmpty)
    }

    @Test("Every configured host appears in the answer, asked or not")
    func everyHostIsAccountedFor() {
        let (result, _) = sweep(["a", "b", "c"])
        #expect(result.results.map(\.host) == ["a", "b", "c"])
    }

    /// A destination that could be read as an ssh flag, or that carries
    /// whitespace, is refused without being asked — and still appears, with
    /// the reason, rather than vanishing from the fleet.
    @Test("An unusable destination is reported, not attempted")
    func unsafeHostIsNotAsked() {
        let (result, recorder) = sweep(["-oProxyCommand=x", "good"])
        #expect(!recorder.seen.contains("-oProxyCommand=x"))
        #expect(recorder.seen.contains("good"))
        let refused = result.results.first { $0.host == "-oProxyCommand=x" }
        #expect(refused?.issue == "not a usable ssh destination")
        #expect(refused?.answered == false)
    }

    /// Answering with no agents is a fact about that machine. Merging it with
    /// a failure would make an idle machine look unreachable.
    @Test("A host that answers with nothing has answered")
    func emptyAnswerIsAnAnswer() {
        let (result, _) = sweep(["a"])
        #expect(result.results.first?.issue == nil)
        #expect(result.results.first?.answered == true)
    }

    // MARK: - Fairness across a large fleet

    /// Past the cap the remaining machines are named in the answer with a
    /// reason, rather than being dropped — someone with three hundred hosts
    /// needs to know which ones are not being watched.
    @Test("Beyond the fleet limit, the rest are told why")
    func beyondTheFleetLimit() {
        let hosts = (0..<(RemoteTmux.fleetLimit + 3)).map { "h\($0)" }
        let (result, recorder) = sweep(hosts)
        #expect(result.results.count == hosts.count)
        #expect(recorder.seen.count == RemoteTmux.fleetLimit)
        let excluded = result.results.suffix(3)
        for host in excluded {
            #expect(host.issue?.contains("first 256") == true,
                    "a host past the limit was dropped instead of explained")
        }
    }

    /// The sweep resumes where the last one stopped, which is the whole of
    /// how a fleet larger than one pass gets seen at all.
    @Test("A complete pass wraps back to the beginning")
    func completePassWraps() {
        #expect(sweep(["a", "b", "c"]).0.nextIndex == 0)
        #expect(sweep(["a", "b", "c"], startIndex: 1).0.nextIndex == 1)
    }

    /// The case that matters, and the one a complete pass cannot show: after
    /// a full pass the next index equals the start whatever the rule is, so
    /// only a pass that ran out of time can tell "where we stopped" from
    /// "where we began". Without this a fleet too large for one pass would
    /// ask the same machines every time and never reach the rest.
    @Test("A pass that runs out of time resumes where it stopped")
    func partialPassResumes() {
        let ticks = Ticker(values: [0, 0, 0, 0, 0, 100, 100, 100, 100])
        let (result, recorder) = sweep((0..<6).map { "h\($0)" }, clock: { ticks.next() })
        #expect(recorder.seen.count < 6, "the whole fleet was reached")
        #expect(result.nextIndex == recorder.seen.count,
                "the next pass would start over instead of continuing")
        #expect(result.nextIndex != 0, "nothing was carried to the next pass")
    }

    @Test("A sweep starts where it was told to")
    func startIndexIsHonoured() {
        let (_, recorder) = sweep(["a", "b", "c"], startIndex: 1)
        #expect(recorder.seen == ["b", "c", "a"])
    }

    /// A start index past the end wraps rather than skipping the pass, which
    /// is what a shrinking host list produces.
    @Test("A start index beyond the list wraps", arguments: [3, 4, 7, 300])
    func startIndexWraps(_ start: Int) {
        let (_, recorder) = sweep(["a", "b", "c"], startIndex: start)
        #expect(recorder.seen.count == 3)
        #expect(Set(recorder.seen) == ["a", "b", "c"])
    }

    @Test("A negative start index is the beginning, not a crash")
    func negativeStartIndex() {
        let (_, recorder) = sweep(["a", "b", "c"], startIndex: -5)
        #expect(recorder.seen == ["a", "b", "c"])
    }

    @Test("An empty fleet is a finished sweep, not an error")
    func emptyFleet() {
        let (result, recorder) = sweep([])
        #expect(result.results.isEmpty)
        #expect(result.nextIndex == 0)
        #expect(recorder.seen.isEmpty)
    }

    // MARK: - The time budget

    /// The pass has a budget. What it did not reach is named and explained,
    /// so a fleet too large for one pass reports progress rather than
    /// failure.
    @Test("What the budget did not reach is deferred, not failed")
    func budgetDefersTheRest() {
        // A clock that jumps past the budget after the first host.
        let ticks = Ticker(values: [0, 0, 0, 100, 100, 100, 100, 100])
        let (result, recorder) = sweep((0..<5).map { "h\($0)" },
                                       duration: 30, clock: { ticks.next() })
        #expect(recorder.seen.count < 5, "the budget was ignored")
        let deferred = result.results.filter { $0.issue?.contains("Not checked") == true }
        #expect(!deferred.isEmpty)
        #expect(deferred.allSatisfy { $0.answered == false })
    }

    /// A clock that stands still must not make the sweep run for ever, and a
    /// clock that goes backwards — a correction mid-pass — must stop it
    /// rather than produce a negative elapsed time.
    @Test("A clock that goes backwards stops the pass")
    func backwardsClockStops() {
        let ticks = Ticker(values: [100, 100, 50])
        let (_, recorder) = sweep((0..<5).map { "h\($0)" }, clock: { ticks.next() })
        #expect(recorder.seen.count < 5)
    }

    @Test("A budget of nothing asks nobody")
    func zeroBudget() {
        let (result, recorder) = sweep(["a", "b"], duration: 0)
        #expect(recorder.seen.isEmpty)
        #expect(result.results.allSatisfy { $0.answered == false })
    }

    @Test("A budget that is not a number asks nobody", arguments: [
        Double.nan, .infinity,
    ])
    func nonFiniteBudget(_ duration: TimeInterval) {
        let (_, recorder) = sweep(["a", "b"], duration: duration)
        #expect(recorder.seen.isEmpty, "a budget of \(duration) ran the pass anyway")
    }

    /// Nobody may ask for an hour of SSH: the ceiling is fixed here rather
    /// than trusted from the caller.
    @Test("A budget longer than the ceiling is the ceiling")
    func budgetIsCapped() {
        // With the clock at 29 the pass is inside a 30s ceiling and runs; a
        // caller asking for 3600 cannot extend it past that.
        let ticks = Ticker(values: [0, 29, 29, 31, 31, 31, 31])
        let (_, recorder) = sweep((0..<4).map { "h\($0)" }, duration: 3_600,
                                  clock: { ticks.next() })
        #expect(recorder.seen.count < 4, "a caller extended the pass past its ceiling")
    }

    // MARK: - Cancellation

    @Test("A cancelled pass asks nobody and defers everyone")
    func cancelledPass() {
        let (result, recorder) = sweep(["a", "b"], cancellation: { true })
        #expect(recorder.seen.isEmpty)
        #expect(result.results.allSatisfy { $0.answered == false })
    }
}

/// A clock that returns a scripted series and then holds its last value.
private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]
    private var index = 0
    init(values: [TimeInterval]) { self.values = values }
    func next() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

/// The claim the whole design rests on, and the one thing the suite above
/// never asked: "Network calls run outside the lock; completion order cannot
/// reorder the published fleet."
///
/// The lock inside the queue is not demonstrated by any of this and says so
/// here rather than in a catalogue entry that would sit as a permanent
/// survivor: eight hosts across four workers is too little contention for a
/// dictionary to come apart, and inflating the fleet to force it would be a
/// test of how many threads a machine has. What is held is the property —
/// the right answer under the right name, once each.
///
/// Every test there uses one worker and a scanner that returns at once, so
/// the hosts come back in the order they were asked and would do so whether
/// the results were keyed by index or simply appended. Four SSH round trips
/// to four machines do not finish in the order they started — that is the
/// point of running them at once — and a fleet that reorders itself puts one
/// machine's agents under another machine's name.
@Suite("Hosts keep their own answers whatever order the network replies in")
struct RemoteSweepOrderingTests {

    /// Answers in reverse: the last host asked replies first. Sleeps are
    /// short and the assertion does not depend on them landing in any exact
    /// order — only on them not landing in the order they were asked.
    /// Counts what each host was actually asked, which the results cannot
    /// show: handing one index to two workers overwrites the answer with an
    /// identical one, so the fleet looks right and the machine was asked
    /// twice. An SSH round trip per host is the cost this exists to bound.
    private final class Asks: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func record(_ host: String) { lock.lock(); counts[host, default: 0] += 1; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }
        var most: Int { lock.lock(); defer { lock.unlock() }; return counts.values.max() ?? 0 }
    }

    private func scrambled(_ hosts: [String], maxConcurrent: Int,
                           asks: Asks = Asks()) -> RemoteTmux.Sweep {
        let order = Dictionary(uniqueKeysWithValues: hosts.enumerated().map { ($1, $0) })
        return RemoteTmux.scanSweep(
            hosts: hosts, startIndex: 0, duration: 30, maxConcurrent: maxConcurrent,
            clock: { 0 }, cancellation: { false },
            scanner: { host, _ in
                asks.record(host)
                let index = order[host] ?? 0
                usleep(UInt32((hosts.count - index) * 2_000))
                // The row names the host it came from, so a result landing
                // under the wrong name is visible rather than merely
                // suspected.
                return RemoteTmux.Result(
                    rows: [AgentRow(id: "\(host)-row", agentID: "claude-code",
                                    name: host, cwd: "/synthetic/\(host)",
                                    state: .waiting)],
                    issue: nil)
            })
    }

    @Test("Answers arriving backwards are still filed under the right host",
          arguments: [1, 2, 4])
    func outOfOrderRepliesKeepTheirHost(maxConcurrent: Int) {
        let hosts = (1...8).map { "host-\($0)" }
        let sweep = scrambled(hosts, maxConcurrent: maxConcurrent)

        #expect(sweep.results.map(\.host) == hosts,
                Comment(rawValue: "the fleet came back as \(sweep.results.map(\.host))"))
        for result in sweep.results {
            #expect(result.rows.first?.name == result.host,
                    Comment(rawValue: "\(result.host) is showing "
                            + "\(result.rows.first?.name ?? "nothing")'s agents"))
        }
    }

    /// And every host is asked exactly once, however many workers there are.
    /// Handing the same index to two workers would show one machine twice
    /// and another not at all.
    @Test("Each host is asked once, whatever the concurrency",
          arguments: [1, 2, 4])
    func everyHostAskedOnce(maxConcurrent: Int) {
        let hosts = (1...8).map { "host-\($0)" }
        let asks = Asks()
        let sweep = scrambled(hosts, maxConcurrent: maxConcurrent, asks: asks)
        #expect(Set(sweep.results.map(\.host)).count == hosts.count,
                "a host appears more than once")
        #expect(sweep.results.allSatisfy { $0.issue == nil },
                "a host was never asked")
        // Counted, not inferred from the results: asking one machine twice
        // overwrites its answer with the same answer, so the fleet looks
        // perfect and the round trip happened anyway.
        #expect(asks.total == hosts.count,
                Comment(rawValue: "\(asks.total) round trips for \(hosts.count) hosts"))
        #expect(asks.most == 1, Comment(rawValue: "a host was asked \(asks.most) times"))
    }
}
