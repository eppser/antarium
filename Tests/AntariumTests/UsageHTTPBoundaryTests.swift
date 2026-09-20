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
