import Foundation
import Testing
@testable import Antarium

@Suite("Remote scan lifecycle", .serialized)
@MainActor
struct RemoteScanLifecycleTests {
    private actor Worker {
        private var pending: [Int:CheckedContinuation<RemoteTmux.Sweep,Never>] = [:]
        private(set) var count = 0
        func run() async -> RemoteTmux.Sweep {
            let index = count; count += 1
            return await withCheckedContinuation { pending[index] = $0 }
        }
        func finish(_ index:Int,next:Int) {
            pending.removeValue(forKey:index)?.resume(returning:.init(results:[.init(host:"fixture-\(index)")],nextIndex:next))
        }
    }
    private func waitForCalls(_ desired:Int,worker:Worker) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while await worker.count < desired, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds:1_000_000)
        }
        #expect(await worker.count == desired)
    }
    @Test("An old cancelled completion cannot clear or publish over a replacement sweep")
    func replacement() async throws {
        let worker = Worker()
        let controller = RemoteScanController(worker:{ _,_ in await worker.run() })
        var published:[String] = []
        controller.start(hosts:["fixture"]) { published += $0.map(\.host) }
        try await waitForCalls(1,worker:worker)
        controller.cancel()
        controller.start(hosts:["fixture"]) { published += $0.map(\.host) }
        try await waitForCalls(2,worker:worker)
        await worker.finish(0,next:99)
        try await Task.sleep(nanoseconds:10_000_000)
        #expect(controller.isRunning)
        #expect(controller.nextIndex == 0)
        #expect(published.isEmpty)
        await worker.finish(1,next:2)
        try await Task.sleep(nanoseconds:10_000_000)
        #expect(!controller.isRunning)
        #expect(controller.nextIndex == 2)
        #expect(published == ["fixture-1"])
    }
    @Test("Repeated refresh requests stay single-flight and stopping suppresses publication")
    func singleFlight() async throws {
        let worker = Worker()
        let controller = RemoteScanController(worker:{ _,_ in await worker.run() })
        var publications = 0
        controller.start(hosts:["fixture"]) { _ in publications += 1 }
        controller.start(hosts:["fixture"]) { _ in publications += 1 }
        try await waitForCalls(1,worker:worker)
        controller.cancel()
        await worker.finish(0,next:1)
        try await Task.sleep(nanoseconds:10_000_000)
        #expect(publications == 0)
        #expect(!controller.isRunning)
    }
    @Test("Changing the configured fleet cancels its obsolete pass immediately")
    func configurationChange() async throws {
        let worker = Worker()
        let controller = RemoteScanController(worker:{ _,_ in await worker.run() })
        var publications = 0
        controller.start(hosts:["fixture-old"]) { _ in publications += 1 }
        try await waitForCalls(1,worker:worker)
        controller.reconcile(hosts:["fixture-old"])
        #expect(controller.isRunning)
        controller.reconcile(hosts:["fixture-new"])
        #expect(!controller.isRunning)
        await worker.finish(0,next:1)
        try await Task.sleep(nanoseconds:10_000_000)
        #expect(publications == 0)
    }
}
