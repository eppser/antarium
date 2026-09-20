import Foundation

/// Owns one remote sweep independently of the fast local scan. The worker is
/// injectable so lifecycle races can be tested without SSH or user settings.
@MainActor
final class RemoteScanController {
    typealias Worker = @Sendable ([String],Int) async -> RemoteTmux.Sweep
    private let worker: Worker
    private var task: Task<Void,Never>?
    private var generations = ScanGeneration()
    private var activeHosts: [String]?
    private(set) var nextIndex = 0
    var isRunning: Bool { task != nil }
    init(worker:@escaping Worker = { hosts,index in await RemoteTmux.scanSweepAsync(hosts:hosts,startIndex:index) }) {
        self.worker = worker
    }
    func start(hosts:[String],publish:@escaping @MainActor ([RemoteTmux.HostResult]) -> Void) {
        guard task == nil else { return }
        let worker = worker, index = nextIndex, generation = generations.begin()
        activeHosts = hosts
        task = Task { [weak self] in
            let sweep = await worker(hosts,index)
            guard let self, self.generations.isCurrent(generation) else { return }
            defer { self.task = nil; self.activeHosts = nil }
            guard !Task.isCancelled else { return }
            self.nextIndex = sweep.nextIndex
            publish(sweep.results)
        }
    }
    func reconcile(hosts:[String]) {
        if let activeHosts, activeHosts != hosts { cancel() }
    }
    func cancel() {
        _ = generations.begin()
        task?.cancel(); task = nil; activeHosts = nil
    }
}
