import Foundation

/// Reads a response body in chunks, under a hard byte cap.
///
/// The obvious way to bound a body is `for try await byte in session.bytes(…)`,
/// checking the running total each time. That is what this replaced, and it is
/// pathologically slow: measured against a local server, 1 MB took 9–11
/// seconds of pure CPU, versus 1–2 ms read in bulk. The cost is the async
/// suspension per element, so the size of the response decides how bad it gets
/// — and the 2 MiB cap the code already enforced meant a legitimate large
/// response could burn twenty seconds of CPU without ever tripping the request
/// timeout, which only measures the network.
///
/// `URLSession.data(for:delegate:)` cannot be used to fix it: the task
/// delegate's `didReceive data:` is never called on that path, so the cap it
/// appears to enforce enforces nothing. Verified before relying on it. A
/// session-level delegate does receive the chunks, and can refuse an oversized
/// body twice over — on the declared length before a byte arrives, and on the
/// running total for a chunked reply that declares no length at all.
final class BoundedBodyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    enum Failure: Error {
        case tooLarge, noResponse
        /// The session was released while this transfer was in flight —
        /// the descriptor behind it changed or went away.
        case sessionInvalidated
        /// The server answered with a redirect to somewhere the credential on
        /// this request was not meant for. Reported in its own right rather
        /// than left to whatever the 3xx eventually looks like — the refusal
        /// is the interesting event, and the caller has to be able to say so.
        case redirectRefused(to: String)
    }

    private struct Pending {
        var data = Data()
        var response: URLResponse?
        var tooLarge = false
        var refusedRedirect: String?
        let finish: (Result<(Data, URLResponse), Error>) -> Void
    }

    private let limit: Int
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    init(limit: Int) {
        self.limit = limit
        super.init()
    }

    /// Runs one request and returns its bounded body. Cancelling the
    /// surrounding task cancels the transfer.
    func body(for request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[task.taskIdentifier] = Pending { continuation.resume(with: $0) }
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - URLSessionDataDelegate

    /// Credentials travel on this session. `httpAdditionalHeaders` puts the
    /// Authorization header on every request the session makes, redirect
    /// targets included, and URLSession does not drop it when the host
    /// changes — a usage endpoint answering `302 Location: elsewhere` would
    /// hand that host the user's token. The redirect is followed only when
    /// scheme and host are unchanged; anything else is refused, and the 3xx
    /// itself becomes the response so the failure is visible rather than a
    /// silent hop.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url,
              let fromHost = from.host?.lowercased(), !fromHost.isEmpty,
              to.host?.lowercased() == fromHost,
              to.scheme?.lowercased() == from.scheme?.lowercased() else {
            lock.lock()
            pending[task.taskIdentifier]?.refusedRedirect =
                request.url?.host ?? "another host"
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let id = dataTask.taskIdentifier
        lock.lock()
        pending[id]?.response = response
        // A declared length over the cap is refused before a byte is read.
        let refuse = response.expectedContentLength > Int64(limit)
        if refuse { pending[id]?.tooLarge = true }
        lock.unlock()
        completionHandler(refuse ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        lock.lock()
        guard var entry = pending[id] else { lock.unlock(); return }
        // And a reply that declares no length is refused on the running total,
        // which is the case the declared-length check cannot cover.
        if entry.data.count + data.count > limit {
            entry.tooLarge = true
            pending[id] = entry
            lock.unlock()
            dataTask.cancel()
            return
        }
        entry.data.append(data)
        pending[id] = entry
        lock.unlock()
    }

    /// A session with a delegate keeps that delegate alive until it is
    /// invalidated, so this is where a released session's reader is let go.
    /// Any transfer still in flight is failed rather than left suspended: a
    /// continuation nobody resumes is a `fetch` that never returns.
    ///
    /// That drain has no mutation in the catalogue, deliberately. Every
    /// reachable path resumes its continuation from `didCompleteWithError`
    /// before invalidation finishes, so removing it breaks no test — and it
    /// stays anyway, because the failure it guards against is a provider that
    /// hangs for ever rather than one that reports something wrong.
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        let abandoned = pending
        pending.removeAll()
        lock.unlock()
        for (_, entry) in abandoned {
            entry.finish(.failure(error ?? Failure.sessionInvalidated))
        }
        UsageHTTP.forget(session)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let entry = pending.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Our own refusal outranks the cancellation it caused, so the caller
        // is told the body was too large rather than that it was cancelled.
        if entry.tooLarge { entry.finish(.failure(Failure.tooLarge)); return }
        // Likewise our own refusal of a redirect: whatever the transfer went
        // on to do, the reason it did not succeed is that it was pointed
        // somewhere the credential could not follow.
        if let host = entry.refusedRedirect {
            entry.finish(.failure(Failure.redirectRefused(to: host)))
            return
        }
        if let error { entry.finish(.failure(error)); return }
        guard let response = entry.response else {
            entry.finish(.failure(Failure.noResponse))
            return
        }
        entry.finish(.success((entry.data, response)))
    }
}
