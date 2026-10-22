import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.ping")

/// Implements XEP-0199 XMPP Ping — responds to incoming pings and
/// sends periodic keepalive pings to the server.
public final class PingModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        var keepAliveTask: Task<Void, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let pingInterval: Duration
    private let pingTimeout: Duration

    public var features: [String] {
        [XMPPNamespaces.ping]
    }

    /// `pingTimeout` is how long a keepalive ping may go unanswered before the session counts as lost. The request's own
    /// 30-second timeout caps it.
    public init(pingInterval: Duration = .seconds(300), pingTimeout: Duration = .seconds(30)) {
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        guard state.withLock({ $0.context }) != nil else { return }

        let interval = pingInterval
        let timeout = pingTimeout
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                // A lost session's teardown cancels this loop.
                await checkLiveness(timeout: timeout)
            }
        }

        state.withLock { $0.keepAliveTask = task }
    }

    public func handleResume() async throws {
        try await handleConnect()
    }

    public func handleDisconnect() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            let task = state.keepAliveTask
            state.keepAliveTask = nil
            return task
        }
        task?.cancel()
    }

    // MARK: - Liveness

    private enum Liveness {
        case alive
        case lost
        case unknown
    }

    /// Pings the server and ends the session as lost when no answer comes within `timeout`, or within the request's own
    /// timeout when that is shorter. Any answer, an error included, shows the connection is alive. A ping that cannot go out, such as on a session that has already ended,
    /// changes nothing.
    public func checkLiveness(timeout: Duration) async {
        guard let context = state.withLock({ $0.context }) else { return }
        let liveness = await withTaskGroup(of: Liveness.self) { group in
            group.addTask { await Self.ping(context) }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .lost
                } catch {
                    return .unknown
                }
            }
            // Cancelling the unanswered ping resolves its pending request, so the group ends at once.
            let first = await group.next() ?? .unknown
            group.cancelAll()
            return first
        }
        guard case .lost = liveness, !Task.isCancelled else { return }
        log.info("The server did not answer a ping")
        context.reportConnectionLost("The server stopped responding")
    }

    private static func ping(_ context: ModuleContext) async -> Liveness {
        var pingIQ = XMPPIQ(type: .get, id: context.generateID())
        pingIQ.element.addChild(XMLElement(name: "ping", namespace: XMPPNamespaces.ping))
        do {
            _ = try await context.sendIQ(pingIQ)
            return .alive
        } catch is XMPPStanzaError {
            return .alive
        } catch XMPPClientError.timeout {
            return .lost
        } catch {
            log.debug("Ping failed: \(error)")
            return .unknown
        }
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws -> Bool {
        guard iq.isGet,
              iq.childElement?.name == "ping",
              iq.childElement?.namespace == XMPPNamespaces.ping else {
            return false
        }

        let context = state.withLock { $0.context }
        guard let context else { return true }

        if let result = XMPPIQ.resultReply(for: iq) {
            Task {
                do {
                    try await context.sendStanza(result)
                } catch {
                    log.warning("Failed to respond to ping: \(error)")
                }
            }
        }
        return true
    }
}
