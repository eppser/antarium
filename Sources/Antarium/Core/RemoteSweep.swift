import Foundation

extension RemoteTmux {
    struct Sweep: Sendable {
        var results: [HostResult]
        var nextIndex: Int
    }
    typealias Scanner = @Sendable (String, @Sendable () -> Bool) -> Result
    static let fleetLimit = 256

    /// Mutable scheduling state is entirely behind one lock. Network calls run
    /// outside the lock; completion order cannot reorder the published fleet.
    private final class SweepQueue: @unchecked Sendable {
        private let lock = NSLock()
        private let count: Int
        private let start: Int
        private var taken = 0
        private var values: [Int:HostResult] = [:]
        init(count:Int,start:Int) { self.count = count; self.start = start }
        func take() -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard taken < count else { return nil }
            let index = (start + taken) % count; taken += 1
            return index
        }
        func store(_ result:HostResult,index:Int) {
            lock.lock(); values[index] = result; lock.unlock()
        }
        func finish(hosts:[String],deferred:String) -> Sweep {
            lock.lock(); defer { lock.unlock() }
            let results = hosts.enumerated().map { index,host in
                values[index] ?? HostResult(host:host,issue:index >= count
                    ? "Only the first 256 configured hosts can be monitored. Remove unused hosts to include this machine."
                    : deferred)
            }
            return Sweep(results:results,nextIndex:count == 0 ? 0 : (start + taken) % count)
        }
    }
    static func normalizedHosts(_ hosts:[String]) -> [String] {
        var seen = Set<String>()
        return hosts.map { $0.trimmingCharacters(in:.whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    static func scanSweep(hosts:[String],startIndex:Int = 0,duration:TimeInterval = 30,
                          maxConcurrent:Int = 4,
                          clock:@escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                          cancellation:@escaping @Sendable () -> Bool = { false },
                          scanner:@escaping Scanner = { host,stop in scan(host:host,cancellation:stop) }) -> Sweep {
        let unique = normalizedHosts(hosts)
        let count = min(fleetLimit,unique.count)
        let start = count == 0 ? 0 : max(0,startIndex) % count
        let queue = SweepQueue(count:count,start:start)
        let began = clock()
        let span = duration.isFinite ? min(30,max(0,duration)) : 0
        let shouldStop: @Sendable () -> Bool = {
            let now = clock()
            return cancellation() || !began.isFinite || !now.isFinite || now < began || now - began >= span
        }
        let deferred = "Not checked in this pass. Discovery will continue within its time and concurrency limits."
        DispatchQueue.concurrentPerform(iterations:min(count,min(4,max(1,maxConcurrent)))) { _ in
            while !shouldStop(), let index = queue.take() {
                let host = unique[index]
                guard isSafeHost(host) else {
                    queue.store(HostResult(host:host,issue:"not a usable ssh destination"),index:index)
                    continue
                }
                let result = scanner(host,shouldStop)
                queue.store(shouldStop() ? HostResult(host:host,issue:deferred)
                    : HostResult(host:host,rows:result.rows,issue:result.issue),index:index)
            }
        }
        return queue.finish(hosts:unique,deferred:deferred)
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func cancel() { lock.lock(); stopped = true; lock.unlock() }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }
    static func scanSweepAsync(hosts:[String],startIndex:Int) async -> Sweep {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos:.utility).async {
                    continuation.resume(returning:scanSweep(hosts:hosts,startIndex:startIndex,
                        cancellation:{ cancellation.isCancelled() }))
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}
