import Foundation
import Testing
@testable import Antarium

private final class SyntheticUsageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "usage.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: Data
        let status: Int
        switch path {
        case "/large": body = Data(("{\"padding\":\"" + String(repeating: "x", count: 2 * 1_024 * 1_024) + "\"}").utf8); status = 200
        case "/big": body = Data(("{\"padding\":\"" + String(repeating: "x", count: 1_000_000) + "\"}").utf8); status = 200
        case "/declared-huge":
            // Small body, enormous declared length: the cap has to refuse this
            // before a byte of it is read, which is a different check from the
            // running total and the only one a well-behaved server trips.
            body = Data("{}".utf8); status = 200
        case "/malformed": body = Data("not json".utf8); status = 200
        case "/denied": body = Data("{}".utf8); status = 401
        default: body = Data("{\"used\":0}".utf8); status = 200
        }
        var headers = ["Content-Type": "application/json"]
        if path == "/declared-huge" { headers["Content-Length"] = "9999999" }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Usage HTTP response boundaries")
struct UsageHTTPBoundaryTests {
    /// Built the way a provider builds one, so the bounded-body delegate and
    /// its cap are actually in the path being tested.
    private func session() -> URLSession {
        UsageHTTP.makeSession(headers: [:], protocolClasses: [SyntheticUsageProtocol.self])
    }
    @Test("Oversized usage responses are rejected even without Content-Length")
    func oversized() async {
        let client = session(); defer { client.invalidateAndCancel() }
        do {
            _ = try await UsageHTTP.getJSON(URL(string: "https://usage.invalid/large")!, headers: [:], session: client)
            Issue.record("Oversized response was accepted")
        } catch let error as ProviderError {
            // Specifically the cap, not merely "some ProviderError" — this
            // test passed for the wrong reason once already.
            #expect(error == .badResponse("Usage response exceeds the 2 MiB safety limit."))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
    @Test("A response that declares an oversized length is refused before it is read")
    func declaredLengthIsRefused() async {
        let client = session(); defer { client.invalidateAndCancel() }
        do {
            _ = try await UsageHTTP.getJSON(URL(string: "https://usage.invalid/declared-huge")!,
                                            headers: [:], session: client)
            Issue.record("a response declaring 9.5 MB was accepted")
        } catch let error as ProviderError {
            #expect(error == .badResponse("Usage response exceeds the 2 MiB safety limit."))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A large but legal response is read in bulk, not a byte at a time")
    func largeResponseIsNotReadByteByByte() async throws {
        let client = session(); defer { client.invalidateAndCancel() }
        let started = Date()
        let json = try await UsageHTTP.getJSON(URL(string: "https://usage.invalid/big")!,
                                               headers: [:], session: client)
        let elapsed = Date().timeIntervalSince(started)
        #expect((json["padding"] as? String)?.count == 1_000_000)
        // Read in bulk this is milliseconds. Accumulated one byte at a time
        // through an async sequence — which is what this replaced — the same
        // megabyte measured 9 to 11 seconds against a local server. The bound
        // is deliberately loose: it is here to catch that regression, not to
        // police normal variation on a busy machine.
        #expect(elapsed < 2.0, "1 MB usage response took \(elapsed)s to read")
    }

    @Test("Explicit zero is preserved and malformed or rejected responses are errors")
    func statuses() async throws {
        let client = session(); defer { client.invalidateAndCancel() }
        let zero = try await UsageHTTP.getJSON(URL(string: "https://usage.invalid/zero")!, headers: [:], session: client)
        #expect(zero["used"] as? Int == 0)
        for path in ["malformed", "denied"] {
            do {
                _ = try await UsageHTTP.getJSON(URL(string: "https://usage.invalid/\(path)")!, headers: [:], session: client)
                Issue.record("Invalid response was accepted")
            } catch { #expect(error is ProviderError) }
        }
    }
}

/// A server that answers slowly, so a release can happen while a request is
/// still in flight.
private final class SlowUsageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "slow.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(#"{"used":0.25}"#.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// Releasing a session is not cancelling what it is doing.
///
/// A descriptor changes while its provider is mid-fetch — a harness file
/// saved from an editor is exactly that — and the reply that is already on
/// its way is still the answer. `finishTasksAndInvalidate` lets it land;
/// `invalidateAndCancel` would turn an ordinary save into a failed reading,
/// which is the kind of flake nobody can reproduce.
@Suite("Releasing a session lets its request finish")
struct SessionReleaseInFlightTests {

    private func session() -> URLSession {
        UsageHTTP.makeSession(headers: [:], protocolClasses: [SlowUsageProtocol.self])
    }

    @Test("A request already in flight still answers after the session is released")
    func inFlightRequestStillAnswers() async throws {
        let client = session()
        async let reply = UsageHTTP.getJSON(URL(string: "https://slow.invalid/usage")!,
                                            headers: [:], session: client)
        // Long enough for the task to have started, short enough to be well
        // inside the protocol's own delay.
        try await Task.sleep(nanoseconds: 100_000_000)
        UsageHTTP.release(client)
        let json = try await reply
        #expect(json["used"] as? Double == 0.25,
                "releasing the session lost a reply that was already coming")
    }

    /// And the reader is let go once it has finished, rather than being kept
    /// by a session nobody holds.
    @Test("The reader is released once the request has landed")
    func readerIsReleasedAfterwards() async throws {
        let client = session()
        #expect(UsageHTTP.isTracked(client))
        _ = try await UsageHTTP.getJSON(URL(string: "https://slow.invalid/usage")!,
                                        headers: [:], session: client)
        UsageHTTP.release(client)
        for _ in 0..<60 where UsageHTTP.isTracked(client) { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!UsageHTTP.isTracked(client))
    }
}

/// Records what a request actually was, so a descriptor's declared method can
/// be checked against what left the app.
private final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var method: String?
    nonisolated(unsafe) static var body: [String: String]?
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); method = nil; body = nil; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "record.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLProtocol strips httpBody into a stream; read it back out.
        var sent: Data?
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 8_192)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            stream.close()
            sent = collected
        } else {
            sent = request.httpBody
        }
        Self.lock.lock()
        Self.method = request.httpMethod
        Self.body = sent.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: String]
        } ?? nil
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"pct":40.0}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A declared POST leaves the app as a POST.
///
/// The decoder tests say the field is parsed and the provider tests say the
/// mapping reads the reply. Neither says the request went out the way the
/// descriptor asked, which is the only part that could not be checked by
/// reading.
@Suite("A posted quota is actually posted", .serialized)
struct PostQuotaTransportTests {

    private func provider(_ quota: [String: Any]) throws -> DescriptorProvider {
        var full: [String: Any] = [
            "windows": ["list": "data", "usedPercent": "pct"],
            "credential": ["kind": "env", "name": "PATH"],
        ]
        full.merge(quota) { _, new in new }
        let object: [String: Any] = [
            "formatVersion": 1, "id": "post-\(UUID().uuidString)", "name": "Post",
            "process": [:], "source": ["kind": "none", "path": ""], "quota": full]
        let d = try HarnessDocument.decode(
            JSONSerialization.data(withJSONObject: object)).descriptor
        return try #require(DescriptorProvider(d, protocolClasses: [RecordingProtocol.self]))
    }

    @Test("A declared POST goes out as a POST, carrying its body")
    func postGoesOutAsPost() async throws {
        RecordingProtocol.reset()
        let p = try provider(["endpoint": "https://record.invalid/usage",
                              "method": "POST", "body": ["scope": "current"]])
        let snapshot = try await p.fetch()
        #expect(RecordingProtocol.method == "POST")
        #expect(RecordingProtocol.body == ["scope": "current"])
        #expect(abs((snapshot.gauges.first?.used ?? 0) - 0.4) < 0.0001)
    }

    /// The same substitution headers get, because a posted key is as common
    /// as a header one and silently sending the literal "{token}" would read
    /// as a wrong key rather than a missing feature.
    @Test("The token is substituted into the body")
    func tokenIsSubstituted() async throws {
        RecordingProtocol.reset()
        let p = try provider(["endpoint": "https://record.invalid/usage",
                              "method": "POST", "body": ["key": "{token}"]])
        _ = try await p.fetch()
        let sent = try #require(RecordingProtocol.body?["key"])
        #expect(sent == ProcessInfo.processInfo.environment["PATH"])
        #expect(!sent.contains("{token}"), "the placeholder was sent as itself")
    }

    @Test("An undeclared method still goes out as a GET")
    func defaultStillGets() async throws {
        RecordingProtocol.reset()
        let p = try provider(["endpoint": "https://record.invalid/usage"])
        _ = try await p.fetch()
        #expect(RecordingProtocol.method == "GET")
    }
}
