import Foundation

/// Shared plumbing for providers: one configured session, one JSON GET, one
/// place that decides what an HTTP status means.
enum UsageHTTP {
    static func makeSession(headers: [String: String]) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = headers
        return URLSession(configuration: cfg)
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
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlErr as URLError {
            throw ProviderError.transport(describe(urlErr, host: host))
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        try check(response, host: host)

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse("\(host) didn't return JSON.")
        }
        return obj
    }

    static func check(_ response: URLResponse, host: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse("Unexpected response from \(host).")
        }
        Log.debug("http", "\(http.statusCode) \(host)")
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
        default: return err.localizedDescription
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
