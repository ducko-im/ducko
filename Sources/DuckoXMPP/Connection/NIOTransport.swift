import NIOCore
import NIOPosix
import NIOSSL

/// Channel ownership is actor-isolated; pipeline state stays on its event loop.
actor NIOTransport: XMPPTransport {
    nonisolated let receivedData: AsyncStream<[UInt8]>
    private let initialContinuation: AsyncStream<[UInt8]>.Continuation
    private let group: any EventLoopGroup
    private let connectTimeout: TimeAmount
    private let handshakeTimeout: Duration
    private let writeTimeout: Duration
    private let trustRoots: [[UInt8]]
    private var attempt: NIOConnectionAttempt?
    private var channel: (any Channel)?
    private var receiving = false
    private var transitioning = false
    private var lastWrite: EventLoopFuture<Void>?
    private(set) var tlsInfo: TLSInfo?
    private var binding: [UInt8]?

    init(
        connectTimeout: TimeAmount = .seconds(30), handshakeTimeout: Duration = .seconds(30), writeTimeout: Duration = .seconds(5),
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton, trustRoots: [[UInt8]] = []
    ) {
        (self.receivedData, self.initialContinuation) = AsyncStream.makeStream()
        self.group = group
        self.connectTimeout = connectTimeout
        self.handshakeTimeout = handshakeTimeout
        self.writeTimeout = writeTimeout
        self.trustRoots = trustRoots
    }

    func connect(host: String, port: UInt16) async throws {
        try await establish(host: host, port: port, serverName: nil)
    }

    func connectWithTLS(host: String, port: UInt16, serverName: String) async throws {
        try await establish(host: host, port: port, serverName: serverName)
    }

    private func establish(host: String, port: UInt16, serverName: String?) async throws {
        guard attempt == nil else { throw XMPPClientError.alreadyConnected }
        let owner = NIOConnectionAttempt(eventLoop: group.next())
        attempt = owner
        transitioning = true
        ClientBootstrap(group: group)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try owner.register(channel)
                    try channel.pipeline.syncOperations.addHandler(NIOReceiveHandler())
                }
            }.connect(host: host, port: Int(port)).cascade(to: owner.connected)
        do {
            let opened = try await owner.connected.futureResult.getAbandoningOnCancel()
            guard attempt === owner, !Task.isCancelled else { throw CancellationError() }
            channel = opened
            let continuation = initialContinuation
            if let serverName {
                try await startTLS(on: opened, owner: owner, serverName: serverName, continuation: continuation)
            } else {
                try await opened.eventLoop.submit {
                    try opened.pipeline.syncOperations.handler(type: NIOReceiveHandler.self).begin(continuation)
                }.get()
                try await opened.setOption(ChannelOptions.autoRead, value: true).get()
            }
            guard attempt === owner, !Task.isCancelled else { throw CancellationError() }
            receiving = true
            transitioning = false
        } catch {
            await close(owner)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if case ChannelError.connectTimeout = error { throw XMPPClientError.timeout }
            if let error = error as? XMPPClientError { throw error }
            throw XMPPClientError.connectionFailed("The server could not be reached")
        }
    }

    func stopReceiving() async {
        guard let channel, let owner = attempt, !transitioning else { return }
        transitioning = true
        _ = try? await lastWrite?.get()
        guard attempt === owner else { return }
        try? await channel.setOption(ChannelOptions.autoRead, value: false).get()
        try? await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.handler(type: NIOReceiveHandler.self).stop()
        }.get()
        guard attempt === owner else { return }
        receiving = false
        transitioning = false
    }

    func upgradeTLS(serverName: String) async throws -> AsyncStream<[UInt8]> {
        guard let channel, let owner = attempt else { throw XMPPClientError.notConnected }
        guard !receiving, !transitioning else {
            throw XMPPClientError.tlsNegotiationFailed("Reading had not stopped before the secure connection started")
        }
        transitioning = true
        _ = try? await lastWrite?.get()
        guard attempt === owner else { throw XMPPClientError.notConnected }
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        do {
            try await startTLS(on: channel, owner: owner, serverName: serverName, continuation: continuation)
            guard attempt === owner, !Task.isCancelled else { throw CancellationError() }
            receiving = true
            transitioning = false
            return stream
        } catch {
            continuation.finish()
            await close(owner)
            throw error
        }
    }

    private func startTLS(on channel: any Channel, owner: NIOConnectionAttempt, serverName: String, continuation: AsyncStream<[UInt8]>.Continuation) async throws {
        let ready = channel.eventLoop.makePromise(of: NIOHandshakeResult.self)
        let roots = trustRoots
        let timeout = handshakeTimeout
        do {
            try await channel.eventLoop.submit {
                let receiver = try channel.pipeline.syncOperations.handler(type: NIOReceiveHandler.self)
                receiver.prepareHandshake(ready, continuation: continuation, timeout: timeout)
                var configuration = TLSConfiguration.makeClientConfiguration()
                configuration.minimumTLSVersion = .tlsv12
                configuration.applicationProtocols = ["xmpp-client"]
                configuration.additionalTrustRoots = try roots.map { try .certificates([NIOSSLCertificate(bytes: $0, format: .der)]) }
                let usesIPIdentity = if case .v4? = try? SocketAddress(ipAddress: serverName, port: 0) { true } else { false }
                if usesIPIdentity { configuration.certificateVerification = .noHostnameVerification }
                let context = try NIOSSLContext(configuration: configuration)
                let owner = NIOLoopBound(receiver, eventLoop: channel.eventLoop)
                // NIOSSL still checks the host name itself after this callback, except for an IP identity.
                let handler = try NIOSSLClientHandler(context: context, serverHostname: usesIPIdentity ? nil : serverName) { chain, promise in
                    verifyCertificateChain(chain, serverName: serverName, trustRoots: roots, promise: promise) { reason in
                        owner.value.recordTrustFailure(reason)
                    }
                }
                try channel.pipeline.syncOperations.addHandler(handler, position: .first)
            }.get()
            try await channel.setOption(ChannelOptions.autoRead, value: true).get()
            let result = try await ready.futureResult.getAbandoningOnCancel()
            guard attempt === owner, !Task.isCancelled else { throw CancellationError() }
            tlsInfo = result.info
            binding = result.binding
        } catch {
            try? await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.handler(type: NIOReceiveHandler.self).failHandshake(error)
            }.get()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if case XMPPClientError.timeout = error {
                throw XMPPClientError.tlsNegotiationFailed("The server did not complete the TLS handshake in time")
            }
            if let error = error as? XMPPClientError { throw error }
            throw XMPPClientError.tlsNegotiationFailed("The secure connection could not be established")
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard let channel, let owner = attempt, !transitioning else { throw XMPPClientError.notConnected }
        do {
            let sent: EventLoopFuture<Void> = channel.writeAndFlush(ByteBuffer(bytes: bytes))
            lastWrite = sent
            try await sent.get(timeout: writeTimeout, ignoringCancellation: true)
        } catch {
            let disconnected = owner.isCancelled
            await close(owner)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if case XMPPClientError.timeout = error {
                throw XMPPClientError.sendFailed("Timed out waiting to send data")
            }
            if disconnected { throw XMPPClientError.notConnected }
            throw XMPPClientError.sendFailed("The connection closed before the data could be sent")
        }
    }

    func disconnect() async {
        initialContinuation.finish()
        guard let owner = attempt else { return }
        await close(owner)
    }

    private func close(_ owner: NIOConnectionAttempt) async {
        let channels = owner.cancel()
        if attempt === owner {
            attempt = nil
            channel = nil
            receiving = false
            transitioning = false
            tlsInfo = nil
            binding = nil
            lastWrite = nil
        }
        for channel in channels {
            try? await channel.closeFuture.get()
        }
    }

    func channelBindingData() -> [UInt8]? {
        binding
    }
}
