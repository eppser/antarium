import Foundation
import Testing
@testable import Antarium

/// Records every request it is asked to serve, with the Authorization header
/// that arrived, so a test can assert what a second host did or did not see.
private final class RedirectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(host: String, authorization: String?)] = []

    static let shared = RedirectRecorder()

    func record(_ host: String, _ authorization: String?) {
        lock.lock(); seen.append((host, authorization)); lock.unlock()
    }
    func reset() { lock.lock(); seen = []; lock.unlock() }
    func requests(to host: String) -> [(host: String, authorization: String?)] {
        lock.lock(); defer { lock.unlock() }
        return seen.filter { $0.host == host }
    }
}

private final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    static let origin = "usage.invalid"
    static let elsewhere = "elsewhere.invalid"

    override class func canInit(with request: URLRequest) -> Bool {
        [origin, elsewhere].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        RedirectRecorder.shared.record(
            url.host ?? "", request.value(forHTTPHeaderField: "Authorization"))

        func redirect(to location: String) {
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": location])!
            // URLSession turns this into a willPerformHTTPRedirection callback.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!),
                                redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        }

        switch url.path {
        case "/offsite":  redirect(to: "https://\(Self.elsewhere)/usage")
        case "/onsite":   redirect(to: "https://\(Self.origin)/ok")
        default:
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"used":1}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// Every usage request carries a credential. Where it is allowed to travel is
/// therefore not only the descriptor author's business — a redirect is chosen
/// by the server, after the request has left.
@Suite("A credential does not follow the response wherever it points", .serialized)
struct RedirectAndSchemeTests {

    private func session() -> URLSession {
        UsageHTTP.makeSession(headers: ["Authorization": "Bearer synthetic-token"],
                              protocolClasses: [RedirectingProtocol.self])
    }

    @Test("A redirect to another host is refused and the token never leaves")
    func offsiteRedirectIsRefused() async throws {
        RedirectRecorder.shared.reset()
        let client = session(); defer { client.invalidateAndCancel() }
        do {
            _ = try await UsageHTTP.getJSON(
                URL(string: "https://\(RedirectingProtocol.origin)/offsite")!,
                headers: [:], session: client)
            Issue.record("An off-site redirect was followed")
        } catch let error as ProviderError {
            guard case .badResponse(let message) = error else {
                Issue.record("Wrong error: \(error)"); return
            }
            #expect(message.contains("redirected"), "the refusal must say what happened: \(message)")
        }
        // The point of the whole exercise: the other host was never called,
        // so it never saw the Authorization header.
        #expect(RedirectRecorder.shared.requests(to: RedirectingProtocol.elsewhere).isEmpty)
    }

    /// Without this the test above passes just as well against a client that
    /// cannot follow any redirect at all, which is not what was built.
    @Test("A redirect within the same host is still followed, credential intact")
    func onsiteRedirectIsFollowed() async throws {
        RedirectRecorder.shared.reset()
        let client = session(); defer { client.invalidateAndCancel() }
        let json = try await UsageHTTP.getJSON(
            URL(string: "https://\(RedirectingProtocol.origin)/onsite")!,
            headers: [:], session: client)
        #expect(json["used"] as? Int == 1)
        let calls = RedirectRecorder.shared.requests(to: RedirectingProtocol.origin)
        #expect(calls.count == 2, "the redirect should have been followed once")
        let carried = calls.allSatisfy { $0.authorization == "Bearer synthetic-token" }
        #expect(carried, "the credential belongs on the host it was meant for")
    }

    @Test("A usage endpoint that is not https is refused before the request")
    func plaintextIsRefused() throws {
        #expect(throws: ProviderError.self) {
            _ = try UsageHTTP.checkedURL(URL(string: "http://usage.invalid/usage")!)
        }
        #expect(throws: ProviderError.self) {
            _ = try UsageHTTP.checkedURL(URL(string: "https:///nohost")!)
        }
        #expect(throws: ProviderError.self) {
            _ = try UsageHTTP.checkedURL(URL(string: "file:///etc/hosts")!)
        }
        let ok = try UsageHTTP.checkedURL(URL(string: "https://usage.invalid/usage")!)
        #expect(ok.host == "usage.invalid")
    }

    @Test("Every shipped usage endpoint is one a credential may be sent to")
    func shippedEndpointsAreHTTPS() throws {
        let urls = try #require(AppResources.bundle.urls(
            forResourcesWithExtension: "json", subdirectory: "harnesses"))
        var checked = 0
        for url in urls {
            let descriptor = try HarnessDocument.decode(Data(contentsOf: url)).descriptor
            guard let endpoint = descriptor.quota?.endpoint else { continue }
            let parsed = try #require(URL(string: endpoint), "\(descriptor.id): \(endpoint)")
            _ = try UsageHTTP.checkedURL(parsed)
            checked += 1
        }
        #expect(checked > 1, "no endpoints were checked, so this proved nothing")
    }
}
