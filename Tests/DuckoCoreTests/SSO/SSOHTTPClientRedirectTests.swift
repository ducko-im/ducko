import Foundation
import os
import Testing
@testable import DuckoCore

/// Answers a request for `/first` with a 307 to `/second` on the same host, and any other path with an empty JSON
/// object. It records each request it loads with its body. Each test uses its own host, so tests running in parallel
/// never see each other's requests.
final class RedirectingURLProtocol: URLProtocol {
    struct Loaded: Sendable, Equatable {
        let path: String
        let method: String?
        let body: Data
    }

    private static let loaded = OSAllocatedUnfairLock(initialState: [String: [Loaded]]())

    static func requests(to host: String) -> [Loaded] {
        loaded.withLock { $0[host] ?? [] }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let body = request.httpBody ?? Self.readAll(request.httpBodyStream)
        let entry = Loaded(path: url.path(), method: request.httpMethod, body: body)
        RedirectingURLProtocol.loaded.withLock { $0[host, default: []].append(entry) }

        if url.path() == "/first" {
            var redirected = URLRequest(url: URL(string: "https://\(host)/second")!)
            redirected.httpMethod = request.httpMethod
            redirected.httpBody = body
            let response = HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://\(host)/second"]
            )!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // A delegate that refuses the redirect completes the task with the redirect response itself.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

struct SSOHTTPClientRedirectTests {
    private static func stubbedConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        return configuration
    }

    private static func post(to host: String) -> URLRequest {
        .formPost(to: URL(string: "https://\(host)/first")!, [("refresh_token", "secret-refresh")])
    }

    @Test
    func `The task delegate hands back no request for a redirect`() async throws {
        let url = try #require(URL(string: "https://auth.example.com/first"))
        let task = URLSession.shared.dataTask(with: url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: nil))
        let next = try URLRequest(url: #require(URL(string: "https://evil.example.com/second")))
        let decision = await RedirectRefusal().urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: next)
        #expect(decision == nil)
    }

    @Test
    func `A plain session follows the stub's redirect and re-sends the body`() async throws {
        let host = "control-\(UUID().uuidString.lowercased()).example"
        let session = URLSession(configuration: Self.stubbedConfiguration())
        let (_, response) = try await session.data(for: Self.post(to: host))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let loaded = RedirectingURLProtocol.requests(to: host)
        #expect(loaded.map(\.path) == ["/first", "/second"])
        #expect(loaded.last?.method == "POST")
        #expect(loaded.last?.body == Data("refresh_token=secret-refresh".utf8))
    }

    @Test
    func `The production client does not follow the redirect and reports a malformed response`() async throws {
        let host = "client-\(UUID().uuidString.lowercased()).example"
        let client = URLSessionSSOHTTPClient(configuration: Self.stubbedConfiguration())
        await #expect(throws: SSOError.malformedResponse) { try await client.send(Self.post(to: host)) }
        #expect(RedirectingURLProtocol.requests(to: host).map(\.path) == ["/first"])
    }

    @Test
    func `The production client refuses a plain http request without sending it`() async throws {
        let host = "plain-\(UUID().uuidString.lowercased()).example"
        let client = URLSessionSSOHTTPClient(configuration: Self.stubbedConfiguration())
        let request = try URLRequest(url: #require(URL(string: "http://\(host)/first")))
        await #expect(throws: SSOError.malformedResponse) { try await client.send(request) }
        #expect(RedirectingURLProtocol.requests(to: host).isEmpty)
    }
}
