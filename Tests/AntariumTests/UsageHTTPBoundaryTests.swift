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
        case "/malformed": body = Data("not json".utf8); status = 200
        case "/denied": body = Data("{}".utf8); status = 401
        default: body = Data("{\"used\":0}".utf8); status = 200
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Usage HTTP response boundaries")
struct UsageHTTPBoundaryTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyntheticUsageProtocol.self]
        return URLSession(configuration: config)
    }
    @Test("Oversized usage responses are rejected even without Content-Length")
    func oversized() async {
        let client = session(); defer { client.invalidateAndCancel() }
        do {
            _ = try await UsageHTTP.getJSON(URL(string: "https://usage.invalid/large")!, headers: [:], session: client)
            Issue.record("Oversized response was accepted")
        } catch { #expect(error is ProviderError) }
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
