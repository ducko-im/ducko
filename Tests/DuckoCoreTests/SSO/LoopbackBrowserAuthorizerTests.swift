import Foundation
import Network
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// An IPv4 address of this Mac that is neither loopback nor link-local, when it has one.
private let nonLoopbackIPv4Address = NetworkInterfaces.localAddresses().first { $0.isIPv4 && !$0.ip.hasPrefix("169.254.") }?.ip

/// Drives `LoopbackBrowserAuthorizer` with real HTTP requests to the port it listens on, found through the redirect URI
/// that `makeURL` embeds in the page it prints.
@Suite(.timeLimit(.minutes(1)))
struct LoopbackBrowserAuthorizerTests {
    private static let callbackPath = "/oauth/callback/0123456789abcdef"
    private static let state = "expected-state"

    /// Starts an authorization and returns its task with the redirect URI the authorizer chose. An authorization that
    /// ends before printing its page, such as one whose listener cannot start, fails with its error.
    private static func start(
        timeout: Duration = .seconds(20)
    ) async throws -> (task: Task<(callback: URL, redirectURI: String), any Error>, redirectURI: String) {
        let printed = AsyncStream.makeStream(of: URL.self)
        let authorizer = LoopbackBrowserAuthorizer(openURL: nil, printURL: { printed.continuation.yield($0) }, timeout: timeout)
        let task = Task {
            defer { printed.continuation.finish() }
            return try await authorizer.authorize(
                callbackPath: callbackPath,
                makeURL: { redirectURI in
                    var components = URLComponents(string: "https://auth.example.com/oauth2/authorize")!
                    components.queryItems = [URLQueryItem(name: "redirect_uri", value: redirectURI)]
                    return components.url!
                },
                expectedState: state
            )
        }
        var iterator = printed.stream.makeAsyncIterator()
        guard let page = await iterator.next() else {
            _ = try await task.value
            Issue.record("The authorization returned without printing its page")
            throw CancellationError()
        }
        let redirectURI = try #require(
            URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value
        )
        return (task, redirectURI)
    }

    private static func status(of url: String) async throws -> Int? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: #require(URL(string: url)))
        return (response as? HTTPURLResponse)?.statusCode
    }

    @Test
    func `The redirect URI is on 127.0.0.1 at the callback path`() async throws {
        let (task, redirectURI) = try await Self.start()
        defer { task.cancel() }
        let components = try #require(URLComponents(string: redirectURI))
        #expect(components.scheme == "http")
        #expect(components.host == "127.0.0.1")
        #expect(components.port != nil && components.port != 0)
        #expect(components.path == Self.callbackPath)
    }

    @Test
    func `The listener accepts connections on 127.0.0.1 only`() {
        let endpoint = LoopbackBrowserAuthorizer.listenerParameters().requiredLocalEndpoint
        guard case let .hostPort(host, port) = endpoint else {
            Issue.record("Expected a host and port, got \(String(describing: endpoint))")
            return
        }
        #expect(host == NWEndpoint.Host("127.0.0.1"))
        #expect(port == .any)
    }

    private static func accepts(host: String, port: UInt16) -> Bool {
        guard let socket = try? connectTCPSocket(host: host, port: port, deadline: .now + .seconds(5)) else { return false }
        close(socket)
        return true
    }

    @Test(.enabled(if: nonLoopbackIPv4Address != nil, "This Mac has no IPv4 address but loopback and link-local ones"))
    func `The listener refuses a connection through another address of this Mac`() async throws {
        let (task, redirectURI) = try await Self.start()
        defer { task.cancel() }
        let port = try UInt16(#require(URLComponents(string: redirectURI)?.port))
        let address = try #require(nonLoopbackIPv4Address)

        #expect(!Self.accepts(host: address, port: port), Comment(rawValue: address))
        #expect(Self.accepts(host: "127.0.0.1", port: port))
    }

    @Test
    func `A wrong path and a wrong state each get 400, then the valid request completes the call`() async throws {
        let (task, redirectURI) = try await Self.start()
        defer { task.cancel() }
        let components = try #require(URLComponents(string: redirectURI))
        let origin = try "http://127.0.0.1:\(#require(components.port))"

        #expect(try await Self.status(of: "\(origin)/oauth/callback/ffffffffffffffff?state=\(Self.state)&code=c") == 400)
        #expect(try await Self.status(of: "\(redirectURI)?state=wrong&code=c") == 400)
        #expect(try await Self.status(of: "\(redirectURI)?code=c") == 400)
        #expect(try await Self.status(of: "\(redirectURI)?state=\(Self.state)&code=the-code") == 200)

        let result = try await task.value
        #expect(result.redirectURI == redirectURI)
        let callback = try #require(URLComponents(url: result.callback, resolvingAgainstBaseURL: false))
        #expect(callback.path == Self.callbackPath)
        #expect(callback.queryItems?.first { $0.name == "code" }?.value == "the-code")
        #expect(callback.queryItems?.first { $0.name == "state" }?.value == Self.state)
    }

    @Test
    func `The call ends with a timeout error when no valid request arrives in time`() async throws {
        let (task, _) = try await Self.start(timeout: .milliseconds(300))
        await #expect(throws: SSOError.timedOut) { try await task.value }
    }

    @Test
    func `The call ends on task cancellation and stops listening`() async throws {
        let (task, redirectURI) = try await Self.start()
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        await #expect(throws: (any Error).self) { try await Self.status(of: "\(redirectURI)?state=\(Self.state)&code=c") }
    }
}
