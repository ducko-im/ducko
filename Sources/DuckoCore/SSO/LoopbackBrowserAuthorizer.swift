import Foundation
import Network

/// Catches the redirect on a port of 127.0.0.1 that the system assigns (RFC 8252 §7.3), for a process that has no
/// URL scheme of its own.
public struct LoopbackBrowserAuthorizer: BrowserAuthorizer {
    private let openURL: (@Sendable (URL) -> Void)?
    private let printURL: @Sendable (URL) -> Void
    private let timeout: Duration

    /// `openURL` opens the sign-in page, or with nil nothing is opened. `printURL` is shown the page either way, so the
    /// user can open it by hand.
    public init(openURL: (@Sendable (URL) -> Void)?, printURL: @escaping @Sendable (URL) -> Void) {
        self.init(openURL: openURL, printURL: printURL, timeout: .seconds(300))
    }

    init(openURL: (@Sendable (URL) -> Void)?, printURL: @escaping @Sendable (URL) -> Void, timeout: Duration) {
        self.openURL = openURL
        self.printURL = printURL
        self.timeout = timeout
    }

    public func authorize(
        callbackPath: String, makeURL: @Sendable (_ redirectURI: String) -> URL, expectedState: String
    ) async throws -> (callback: URL, redirectURI: String) {
        let listener = try NWListener(using: Self.listenerParameters())
        let queue = DispatchQueue(label: "im.ducko.core.sso-loopback")
        let targets = AsyncStream.makeStream(of: String.self)
        defer {
            listener.cancel()
            targets.continuation.finish()
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receiveRequest(on: connection, accumulated: Data()) { target in
                guard let target, Self.matches(target, path: callbackPath, state: expectedState) else {
                    Self.respond(on: connection, status: "400 Bad Request", body: "This is not the sign-in Ducko is waiting for.")
                    return
                }
                Self.respond(on: connection, status: "200 OK", body: "The sign-in is complete. You can close this tab and return to Ducko.")
                targets.continuation.yield(target)
            }
        }
        let port = try await Self.start(listener, on: queue)
        let redirectURI = SSORedirect.loopbackRedirectURI(callbackPath: callbackPath, port: port)
        let url = makeURL(redirectURI)
        printURL(url)
        openURL?(url)

        let stream = targets.stream
        let timeout = timeout
        let target = try await withThrowingTaskGroup(of: String?.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                for await target in stream {
                    return target
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SSOError.timedOut
            }
            guard let first = try await group.next(), let target = first else {
                try Task.checkCancellation()
                throw SSOError.cancelled
            }
            return target
        }
        guard let callback = URL(string: "http://127.0.0.1:\(port)\(target)") else { throw SSOError.malformedResponse }
        return (callback, redirectURI)
    }

    /// TCP on an address of 127.0.0.1 only, so no other host can reach the listener.
    static func listenerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return parameters
    }

    /// Whether a request target is the callback path with this attempt's `state`.
    private static func matches(_ target: String, path: String, state: String) -> Bool {
        guard let components = URLComponents(string: target), components.percentEncodedPath == path else { return false }
        return (components.queryItems ?? []).filter { $0.name == "state" }.map(\.value) == [state]
    }

    private static func start(_ listener: NWListener, on queue: DispatchQueue) async throws -> UInt16 {
        let states = AsyncThrowingStream<UInt16, Error>.makeStream()
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port { states.continuation.yield(port.rawValue); states.continuation.finish() }
            case let .failed(error): states.continuation.finish(throwing: error)
            case .cancelled: states.continuation.finish(throwing: CancellationError())
            case .setup, .waiting: break
            @unknown default: break
            }
        }
        listener.start(queue: queue)
        for try await port in states.stream {
            return port
        }
        throw CancellationError()
    }

    /// Reads up to the end of the request head and hands over the request target, or nil for anything but a GET.
    private static func receiveRequest(
        on connection: NWConnection, accumulated: Data, completion: @escaping @Sendable (String?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { content, _, isComplete, error in
            var data = accumulated
            if let content { data.append(content) }
            if let head = data.range(of: Data("\r\n\r\n".utf8)).map({ data[..<$0.lowerBound] }) {
                let requestLine = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first ?? ""
                let parts = requestLine.split(separator: " ")
                completion(parts.count == 3 && parts[0] == "GET" ? String(parts[1]) : nil)
            } else if isComplete || error != nil || data.count > 16384 {
                connection.cancel()
            } else {
                receiveRequest(on: connection, accumulated: data, completion: completion)
            }
        }
    }

    private static func respond(on connection: NWConnection, status: String, body: String) {
        let page = "<!doctype html><meta charset=utf-8><title>Ducko</title><p>\(body)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\n"
            + "Connection: close\r\n\r\n\(page)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
