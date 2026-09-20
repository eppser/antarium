import Foundation
import Testing
@testable import Antarium

@Suite("Bounded fair multi-machine discovery")
struct RemoteSweepTests {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0, peak = 0
        private var requested: [String] = []
        private var time = 0.0
        func enter(_ host: String) {
            lock.lock(); live += 1; peak = max(peak,live); requested.append(host); lock.unlock()
        }
        func leave() { lock.lock(); live -= 1; lock.unlock() }
        func advance(_ seconds: Double) { lock.lock(); time += seconds; lock.unlock() }
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
        func snapshot() -> (peak:Int,hosts:[String]) {
            lock.lock(); defer { lock.unlock() }; return (peak,requested)
        }
    }
    @Test("A large fleet uses no more than four concurrent SSH jobs")
    func concurrency() {
        let probe = Probe(), hosts = (0..<24).map { "fixture-\($0)" }
        let sweep = RemoteTmux.scanSweep(hosts:hosts,scanner:{ host,_ in
            probe.enter(host); Thread.sleep(forTimeInterval:0.02); probe.leave()
            return .init()
        })
        #expect(probe.snapshot().peak <= 4)
        #expect(probe.snapshot().hosts.count == hosts.count)
        #expect(sweep.results.map(\.host) == hosts)
    }
    @Test("Cancellation prevents new jobs and leaves deferred hosts explicitly unknown")
    func cancelled() {
        let probe = Probe()
        let sweep = RemoteTmux.scanSweep(hosts:["fixture-a","fixture-b"],cancellation:{ true },scanner:{ host,_ in
            probe.enter(host); probe.leave(); return .init()
        })
        #expect(probe.snapshot().hosts.isEmpty)
        #expect(sweep.results.count == 2)
        #expect(sweep.results.allSatisfy { !$0.answered })
    }
    @Test("A deadline rotates the next pass to the first unvisited machine")
    func fairness() {
        let probe = Probe(), hosts = (0..<5).map { "fixture-\($0)" }
        let scanner: RemoteTmux.Scanner = { host,_ in
            probe.enter(host); probe.advance(2); probe.leave(); return .init()
        }
        let first = RemoteTmux.scanSweep(hosts:hosts,startIndex:2,duration:1,maxConcurrent:1,
            clock:{ probe.now() },scanner:scanner)
        #expect(probe.snapshot().hosts == ["fixture-2"])
        #expect(first.nextIndex == 3)
        #expect(first.results.filter(\.answered).count <= 1)
        _ = RemoteTmux.scanSweep(hosts:hosts,startIndex:first.nextIndex,duration:1,maxConcurrent:1,
            clock:{ probe.now() },scanner:scanner)
        #expect(probe.snapshot().hosts == ["fixture-2","fixture-3"])
    }
    @Test("The fleet limit reports excess hosts without launching their jobs")
    func fleetLimit() {
        let probe = Probe(), hosts = (0..<260).map { "fixture-\($0)" }
        let sweep = RemoteTmux.scanSweep(hosts:hosts,scanner:{ host,_ in
            probe.enter(host); probe.leave(); return .init()
        })
        #expect(probe.snapshot().hosts.count == 256)
        #expect(sweep.results.count == 260)
        #expect(sweep.results.suffix(4).allSatisfy { !$0.answered })
    }
    @Test("Unsafe and duplicate destinations never become extra scanner work")
    func destinations() {
        let probe = Probe()
        let sweep = RemoteTmux.scanSweep(hosts:["fixture-a"," fixture-a ","-invalid"],scanner:{ host,_ in
            probe.enter(host); probe.leave(); return .init()
        })
        #expect(probe.snapshot().hosts == ["fixture-a"])
        #expect(sweep.results.count == 2)
        #expect(sweep.results.last?.answered == false)
    }
}
