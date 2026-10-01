import Foundation

/// Shared plumbing for providers: one configured session, one JSON GET, one
/// place that decides what an HTTP status means.
enum UsageHTTP {
    /// The only kind of session a provider may hold.
    ///
    /// Named so that a provider storing one does not have to write
    /// `URLSession`, which the transport contract forbids everywhere but here
    /// — and forbids for a good reason, since it cannot tell a session this
    /// file configured from one built by hand. Spelling it this way says
    /// which it is.
    typealias Session = URLSession

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

    /// Lets a session go when whatever held it is replaced.
    ///
    /// Nothing invalidated a session, and `URLSession` holds its delegate
    /// until something does — so every `DescriptorProvider` dropped because
    /// its descriptor changed left a live session, a live delegate, and an
    /// entry in `readers` that nothing removed. A harness file being edited
    /// is the ordinary way that happens, so the growth followed the user
    /// around rather than being a one-off.
    ///
    /// `finishTasksAndInvalidate` rather than `invalidateAndCancel`: a fetch
    /// already in flight is allowed to finish and answer, and the reader is
    /// released afterwards through `didBecomeInvalidWithError`.
    static func release(_ session: URLSession) {
        session.finishTasksAndInvalidate()
    }

    /// Called by the delegate once the session is done with it.
    static func forget(_ session: URLSession) {
        readerLock.lock()
        readers.removeValue(forKey: ObjectIdentifier(session))
        readerLock.unlock()
    }

    /// Whether this session still holds a reader.
    ///
    /// Asked per session rather than counted, because a count is global: the
    /// first version of this test watched `readers.count` and read other
    /// suites releasing their own sessions as its own failure.
    static func isTracked(_ session: URLSession) -> Bool {
        readerLock.lock()
        defer { readerLock.unlock() }
        return readers[ObjectIdentifier(session)] != nil
    }

    private static func reader(for session: URLSession) -> BoundedBodyDelegate? {
        readerLock.lock()
        defer { readerLock.unlock() }
        return readers[ObjectIdentifier(session)]
    }

    /// Every usage request carries a credential, so the endpoint has to be
    /// one a credential may be sent to. Checked here rather than in each
    /// provider: descriptors are trusted local configuration, but "trusted"
    /// should not extend to sending a bearer token over plaintext because a
    /// descriptor said `http`.
    /// Whether a host is this machine, so plaintext to it never reaches a
    /// wire.
    ///
    /// The loopback literals and `localhost`. Not `0.0.0.0`, which is a bind
    /// address meaning "every interface" rather than a destination meaning
    /// "here" — it usually resolves to this machine and is not promised to,
    /// and anyone who meant loopback can write it. Self-hosted proxies print
    /// `0.0.0.0` in their own quick-start output, so this will be met, and
    /// the refusal says which address to use instead.
    static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name == "::1" { return true }
        // 127.0.0.0/8, all of which is loopback. Requiring four parts is
        // strictness rather than a boundary — `127.1` is a legal shorthand
        // for 127.0.0.1 and is refused here, and a numeric host with more
        // parts than four resolves nowhere — so there is no catalogue entry
        // for it: relaxing it admits nothing a credential could reach.
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            && parts.compactMap { Int($0) }.allSatisfy { $0 >= 0 && $0 <= 255 }
    }

    /// Whether a URL may carry a credential.
    ///
    /// Plaintext to this machine never reaches a wire, and a self-hosted
    /// proxy in front of an agent — LiteLLM and the rest — is http on a port
    /// by default. Refusing those meant the only way to chart one was to put
    /// a certificate in front of a loopback socket, which nobody does.
    ///
    /// Shared with `--check`, which had its own copy insisting on https. A
    /// descriptor that works perfectly at runtime was therefore reported as
    /// broken by the tool whose whole job is telling an author whether their
    /// descriptor works — and it was the self-hosted case, the one the
    /// documentation now tells people to write themselves. Two readings of
    /// one rule, disagreeing in the direction that sends somebody to fix
    /// something that is not wrong.
    static func endpointMayCarryACredential(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || (scheme == "http" && Self.isLoopback(host))
    }

    static func checkedURL(_ url: URL) throws -> URL {
        guard let host = url.host, !host.isEmpty else {
            throw ProviderError.badResponse("That usage endpoint names no host.")
        }
        guard Self.endpointMayCarryACredential(url) else {
            throw ProviderError.badResponse(
                "A usage endpoint must be https, or http on this machine — "
                + "\(url.scheme ?? "that scheme") to \(host) would send the "
                + "credential in the clear.")
        }
        return url
    }

    static func getJSON(_ url: URL, headers: [String: String],
                        session: URLSession) async throws -> [String: Any] {
        let url = try checkedURL(url)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await jsonResponse(for: req, host: url.host ?? "the server", session: session)
    }

    /// A form-encoded POST, which OAuth token endpoints require and JSON is
    /// not accepted for. Same checked URL and same bounded body as the rest.
    static func postForm(_ url: URL, body: String, headers: [String: String],
                         session: URLSession) async throws -> [String: Any] {
        let url = try checkedURL(url)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = Data(body.utf8)
        return try await jsonResponse(for: req, host: url.host ?? "the server", session: session)
    }

    static func postJSON(_ url: URL, body: [String: Any] = [:],
                         headers: [String: String],
                         session: URLSession) async throws -> [String: Any] {
        let url = try checkedURL(url)
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
        } catch BoundedBodyDelegate.Failure.redirectRefused(let elsewhere) {
            throw ProviderError.badResponse(
                "\(host) redirected the usage request to \(elsewhere). It was not followed, "
                + "because the request carries a credential meant only for \(host).")
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
        case 300...399: throw ProviderError.badResponse(
            "\(host) redirected the usage request somewhere else. It was not followed, "
            + "because the request carries a credential meant only for \(host).")
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
        // Transcripts carry a timestamp on nearly every record, and
        // CFDateFormatter was ~18% of a scan on this machine. The overwhelming
        // majority are plain UTC ISO-8601, which is a fixed-width grammar a
        // few comparisons can read. Anything that is not exactly that shape —
        // an offset, a different separator, anything unusual — still goes to
        // the formatter, so nothing is parsed more leniently than before.
        if let fast = fastUTC(s) { return fast }
        dateLock.lock()
        defer { dateLock.unlock() }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// `yyyy-MM-dd'T'HH:mm:ss['.'SSS…]'Z'`, and nothing else.
    ///
    /// Returns nil for every other shape rather than guessing, including dates
    /// the formatter would reject: the calendar arithmetic below is only valid
    /// for a well-formed date, so the ranges are checked rather than assumed.
    /// Sub-second digits read. Nine is nanoseconds — the finest an ISO-8601
    /// timestamp customarily states and finer than a `Date` can hold.
    static let maxFractionDigits = 9

    static func fastUTC(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard b.count >= 20, b.last == UInt8(ascii: "Z"),
              b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              b[10] == UInt8(ascii: "T"), b[13] == UInt8(ascii: ":"),
              b[16] == UInt8(ascii: ":") else { return nil }

        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(b[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              let hour = digits(11..<13), let minute = digits(14..<16),
              let second = digits(17..<19) else { return nil }

        // Digits without accumulating them. `digits` builds `value * 10 +
        // digit` with no ceiling, which is safe over the fixed two- and
        // four-wide fields above and was not over the fraction, whose length
        // nothing bounded: twenty digits overflow `Int` and trap, and a
        // transcript timestamp is written by another application.
        func allDigits(_ range: Range<Int>) -> Bool {
            for index in range where !(48...57).contains(b[index]) { return false }
            return true
        }

        var fraction = 0.0
        if b.count > 20 {
            guard b[19] == UInt8(ascii: ".") else { return nil }
            let end = b.count - 1                       // before the trailing Z
            guard end > 20 else { return nil }
            // Nine digits is nanoseconds, and a `Date` holds nothing finer, so
            // the rest need only be digits for the timestamp to be well formed.
            // Refusing a long fraction outright would discard a legal ISO-8601
            // date; reading all of it is what trapped.
            let significant = min(end, 20 + maxFractionDigits)
            guard let raw = digits(20..<significant), allDigits(significant..<end)
            else { return nil }
            fraction = Double(raw) / pow(10, Double(significant - 20))
        } else {
            guard b[19] == UInt8(ascii: "Z") else { return nil }
        }

        // A leap second is real in the grammar and the formatter accepts it.
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute),
              (0...60).contains(second) else { return nil }

        // Days from the civil epoch — Howard Hinnant's days_from_civil, which
        // is exact for the proleptic Gregorian calendar and has no formatter,
        // locale or time zone anywhere in it.
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        // Reject a day the month does not have — 31 February parses as 3 March
        // in plain arithmetic, and the formatter refuses it.
        guard Self.civilDay(days) == (year, month, day) else { return nil }
        let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second)
        return Date(timeIntervalSince1970: seconds + fraction)
    }

    /// The inverse of the above, used only to reject an impossible date.
    private static func civilDay(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
}
