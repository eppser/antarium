import Foundation
import Testing
@testable import Antarium

/// The scan asks every process on the machine whether it is an agent, and the
/// answer only changes when something it was computed from changes. These pin
/// that the memo is an optimisation and never a different answer.
@Suite("Remembering which processes are agents")
struct ProcessMemoTests {
    private func key(_ pid: Int32 = 7, start: Int64 = 100, path: String = "/bin/a",
                     name: String = "a", argv0: String = "") -> Processes.MeasureMemo.Key {
        .init(pid: pid, start: start, path: path, name: name, argv0: argv0)
    }

    @Test("An unchanged process is asked once")
    func unchangedIsRemembered() {
        var memo = Processes.MeasureMemo(), calls = 0
        for _ in 0..<3 { _ = memo.answer(key(), classifier: "c") { calls += 1; return true } }
        #expect(calls == 1)
    }

    @Test("A change to anything the answer was computed from asks again", arguments: [
        (start: 101 as Int64, path: "/bin/a", name: "a", argv0: ""),   // pid reused by a new process
        (start: 100, path: "/bin/b", name: "a", argv0: ""),            // exec of another binary
        (start: 100, path: "/bin/a", name: "b", argv0: ""),            // renamed
        (start: 100, path: "/bin/a", name: "a", argv0: "pi"),          // interpreter running a script
    ])
    func changedIsAskedAgain(_ change: (start: Int64, path: String, name: String, argv0: String)) {
        var memo = Processes.MeasureMemo(), calls = 0
        #expect(memo.answer(key(), classifier: "c") { calls += 1; return false } == false)
        let changed = key(start: change.start, path: change.path, name: change.name, argv0: change.argv0)
        #expect(memo.answer(changed, classifier: "c") { calls += 1; return true } == true)
        #expect(calls == 2)
    }

    @Test("Editing the harnesses forgets every answer")
    func classifierChangeForgets() {
        var memo = Processes.MeasureMemo(), calls = 0
        _ = memo.answer(key(), classifier: "before") { calls += 1; return false }
        #expect(memo.answer(key(), classifier: "after") { calls += 1; return true } == true)
        #expect(calls == 2)
    }

    @Test("Processes that have gone are forgotten, so the memo cannot grow without bound")
    func vanishedArePruned() {
        var memo = Processes.MeasureMemo()
        for pid in Int32(1)...50 { _ = memo.answer(key(pid), classifier: "c") { true } }
        memo.prune(keeping: [3, 4])
        #expect(memo.count == 2)
    }

    @Test("A capture with the memo sees the same table as one without")
    func memoChangesNothingObservable() throws {
        let plain = try Processes.capture(measureIf: AgentScan.isAgent).table
        _ = try Processes.capture(measureIf: AgentScan.isAgent, classifier: "test")
        let memoised = try Processes.capture(measureIf: AgentScan.isAgent, classifier: "test").table
        // Processes come and go between captures; compare the ones in both.
        for (pid, info) in plain {
            guard let other = memoised[pid], other.startedAt == info.startedAt,
                  other.path == info.path else { continue }
            #expect((other.rss != nil) == (info.rss != nil), "pid \(pid) measured differently")
        }
    }
}

/// `claims` runs for every process against every harness on each scan. It
/// used to assemble its rule — two sorted arrays and a set — on every call.
@Suite("Claiming a process without rebuilding the rule")
struct ClaimsEquivalenceTests {
    /// The rule as `processRule` states it, applied the way `claims` used to.
    private func reference(_ d: HarnessDescriptor, _ p: Processes.Info) -> Bool {
        let rule = d.processRule
        if (rule.pathContains ?? []).contains(where: { p.path.contains($0) }) { return true }
        let base = (p.argv0 as NSString).lastPathComponent
        if (rule.names ?? []).contains(p.name) || (rule.names ?? []).contains(base) { return true }
        return (rule.argv0Contains ?? []).contains { p.argv0.contains($0) }
    }

    @Test("Every shipped harness answers exactly as its rule says")
    func matchesTheRule() throws {
        let shipped = try HarnessCLI.bundledDescriptors()
        var processes: [Processes.Info] = [
            .init(pid: 1, ppid: 1, path: "/usr/bin/zsh", name: "zsh", argv0: "", rss: nil),
            .init(pid: 2, ppid: 1, path: "/opt/homebrew/bin/node", name: "node",
                  argv0: "/usr/local/bin/pi", rss: nil),
        ]
        for d in shipped {
            for probe in d.processRule.installationProbes ?? [] {
                processes.append(.init(pid: 3, ppid: 1, path: probe.path, name: probe.name,
                                       argv0: probe.argv0, rss: nil))
            }
        }
        var positives = 0
        for d in shipped {
            for p in processes {
                let expected = reference(d, p)
                if expected { positives += 1 }
                #expect(d.claims(p) == expected, "\(d.id) disagreed about \(p.path)")
            }
        }
        #expect(positives > 10, "the fixture claims almost nothing, so agreement proves little")
    }
}
