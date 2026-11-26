import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

actor AccountConnectionFactoryProbe: XMPPClientFactory {
    enum Failure: Error { case connect, timeout }
    struct Request {
        let secret: SignInSecret
        let resume: StreamResumeContext?
        let requireTLS: Bool?
        let allowsPLAIN: Bool
    }

    private let transports: [MockTransport]
    private let initialResume: SMResumeState?
    private let firstRelease: AsyncSemaphore?
    private let laterRelease: AsyncSemaphore?
    private let connectHold: AsyncSemaphore?
    private let setupFailure: (any Error)?
    private let pings: Bool
    private let allowsPLAIN: Bool?
    private let requests = AsyncStream.makeStream(of: Request.self)
    private(set) var requestCount = 0

    /// With `connectHold`, the first client's sign-in stops once it is connected, until `connectHold` is signaled. With
    /// `setupFailure`, every client's setup fails with it once connected. With `pings`, every client has a `PingModule`,
    /// so a network change checks its liveness. `allowsPLAIN` overrides every account's permission, by default so
    /// clients send the password to the PLAIN-only handshake fixtures. `nil` leaves it to the account.
    init(
        transports: [MockTransport], initialResume: SMResumeState? = nil, firstRelease: AsyncSemaphore? = nil, laterRelease: AsyncSemaphore? = nil,
        connectHold: AsyncSemaphore? = nil, setupFailure: (any Error)? = nil, pings: Bool = false, allowsPLAIN: Bool? = true
    ) {
        self.transports = transports
        self.initialResume = initialResume
        self.firstRelease = firstRelease
        self.laterRelease = laterRelease
        self.connectHold = connectHold
        self.setupFailure = setupFailure
        self.pings = pings
        self.allowsPLAIN = allowsPLAIN
    }

    func makeClient(account: Account, secret: SignInSecret, resuming: StreamResumeContext?, requireTLSOverride: Bool?, omemoService: OMEMOService?) async -> (XMPPClient, StreamManagementModule) {
        let index = requestCount
        requestCount += 1
        let transport = index < transports.count ? transports[index] : MockTransport(connectError: Failure.connect)
        let sm = StreamManagementModule(previousState: resuming?.streamManagement ?? (index == 0 ? initialResume : nil))
        var builder = XMPPClientBuilder(domain: account.jid.domainPart, username: account.jid.localPart ?? "", secret: secret)
        builder.withTransport(transport)
        builder.withRequireTLS(requireTLSOverride ?? false)
        builder.withAllowsPLAIN(allowsPLAIN ?? account.allowsPLAIN)
        builder.withModule(sm)
        builder.withInterceptor(sm)
        builder.withModule(MUCModule(resuming: resuming?.rooms))
        if index == 0, let connectHold {
            builder.withModule(SetupHold(release: connectHold))
        }
        if let setupFailure {
            builder.withModule(SetupHold(failure: setupFailure))
        }
        if pings {
            builder.withModule(PingModule())
        }
        // A requested disconnect waits for the server to acknowledge what was sent.
        await transport.ackSyncRequests(from: sm)
        let client = await builder.build()
        requests.continuation.yield(Request(
            secret: secret, resume: resuming, requireTLS: requireTLSOverride, allowsPLAIN: allowsPLAIN ?? account.allowsPLAIN
        ))
        if index == 0 { await firstRelease?.wait() } else { await laterRelease?.wait() }
        return (client, sm)
    }

    func nextRequest() async throws -> Request {
        let stream = requests.stream
        return try await withThrowingTaskGroup(of: Request?.self) { group in
            defer { group.cancelAll() }
            group.addTask { for await request in stream {
                return request
            }; return nil }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw Failure.timeout
            }
            return try #require(await group.next()!)
        }
    }
}

/// Waits for `transport` to send a stanza containing `fragment`, then clears what it sent and plays `response`.
func exchange(_ transport: MockTransport, matching fragment: String, response: String) async throws {
    try await awaitSent(on: transport) { $0.contains(fragment) }
    await transport.clearSentBytes()
    await transport.simulateReceive(response)
}

func waitForEvent<Event: Sendable>(_ stream: AsyncStream<Event>, matching: @escaping @Sendable (Event) -> Bool) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        group.addTask {
            for await event in stream where matching(event) {
                return
            }
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw AccountConnectionFactoryProbe.Failure.timeout
        }
        try await group.next()
    }
}
