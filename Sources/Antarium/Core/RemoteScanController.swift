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
    /// Two guards, either of which is enough.
    ///
    /// Bumping the generation makes an in-flight sweep stale; cancelling the
    /// task makes it cancelled. A completion has to pass both, and `cancel()`
    /// sets both, so removing either one alone changes nothing observable —
    /// which is why the catalogue holds one entry removing the pair rather
    /// than two that cannot be caught. The redundancy is deliberate: these
    /// are the checks that stop a superseded sweep publishing rows over a
    /// newer one, and that is not a thing to protect once.
    func cancel() {
        _ = generations.begin()
        task?.cancel(); task = nil; activeHosts = nil
    }
}
