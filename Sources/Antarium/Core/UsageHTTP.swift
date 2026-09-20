import Foundation

/// Shared plumbing for providers: one configured session, one JSON GET, one
/// place that decides what an HTTP status means.
enum UsageHTTP {
    /// Usage responses are small; the cap is here so a misbehaving or
    /// compromised endpoint cannot make the app buffer arbitrarily.
    static let maximumBytes = 2 * 1_024 * 1_024

    /// One delegate per session, shared by its tasks. Holding it here keeps it
    /// alive for the session's lifetime — `URLSession` retains its delegate,
    /// and these sessions live as long as their provider.
    nonisolated(unsafe) private static var readers: [ObjectIdentifier: BoundedBodyDelegate] = [:]
    private static let readerLock = NSLock()

    /// `protocolClasses` exists so a test can substitute a synthetic server
    /// and still travel the production path, delegate and cap included. A test
    /// that builds its own `URLSession` gets no bounded reader, and would pass
    /// on the wrong error.
    static func makeSession(headers: [String: String],
                            protocolClasses: [AnyClass]? = nil) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = headers
        if let protocolClasses { cfg.protocolClasses = protocolClasses }
        let reader = BoundedBodyDelegate(limit: maximumBytes)
        let session = URLSession(configuration: cfg, delegate: reader, delegateQueue: nil)
        readerLock.lock()
        readers[ObjectIdentifier(session)] = reader
        readerLock.unlock()
        return session
    }

    private static func reader(for session: URLSession) -> BoundedBodyDelegate? {
        readerLock.lock()
        defer { readerLock.unlock() }
        return readers[ObjectIdentifier(session)]
    }

    static func getJSON(_ url: URL, headers: [String: String],
                        session: URLSession) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await jsonResponse(for: req, host: url.host ?? "the server", session: session)
    }

    static func postJSON(_ url: URL, body: [String: Any] = [:],
                         headers: [String: String],
                         session: URLSession) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await jsonResponse(for: req, host: url.host ?? "the server", session: session)
    }

    private static func jsonResponse(for req: URLRequest, host: String,
                                     session: URLSession) async throws -> [String: Any] {
        guard let reader = reader(for: session) else {
            throw ProviderError.badResponse("The usage session was not configured to read a bounded body.")
        }
        let data: Data
        do {
            let (body, response) = try await reader.body(for: req, on: session)
            // Status first: a 401 body is not worth parsing, and "sign in" is a
            // better message than "that wasn't JSON".
            try check(response, host: host)
            data = body
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch BoundedBodyDelegate.Failure.tooLarge {
            throw ProviderError.badResponse("Usage response exceeds the 2 MiB safety limit.")
        } catch BoundedBodyDelegate.Failure.noResponse {
            throw ProviderError.badResponse("\(host) returned no response.")
        } catch let error as ProviderError {
            throw error
        } catch let urlErr as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderError.transport(describe(urlErr, host: host))
        } catch {
            throw ProviderError.transport("The usage request could not be completed.")
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse("\(host) didn't return JSON.")
        }
        return obj
    }

    static func check(_ response: URLResponse, host: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse("Unexpected response from \(host).")
        }
        Log.debug("http", "Response status \(http.statusCode)")
        switch http.statusCode {
        case 200...299: return
        case 401, 403:  throw ProviderError.needsAuth("\(host) rejected the saved credentials.")
        case 404:       throw ProviderError.unsupported("\(host) has no usage endpoint at that path.")
        case 429:       throw ProviderError.transport("Rate limited by \(host).")
        case 500...599: throw ProviderError.transport("\(host) is having trouble (\(http.statusCode)).")
        default:        throw ProviderError.badResponse("Usage request failed (HTTP \(http.statusCode)).")
        }
    }

    static func describe(_ err: URLError, host: String) -> String {
        switch err.code {
        case .notConnectedToInternet, .networkConnectionLost: return "No network connection."
        case .timedOut: return "\(host) timed out."
        case .cannotFindHost, .dnsLookupFailed: return "Can't reach \(host)."
        case .cancelled: return "The usage request was cancelled."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "A secure connection to \(host) could not be verified."
        default: return "The usage request to \(host) failed (network error \(err.errorCode))."
        }
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
    private static let dateLock = NSLock()

    static func parseDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        dateLock.lock()
        defer { dateLock.unlock() }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
