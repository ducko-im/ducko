/// Owns transport, XML parser, and the unified `events` stream. Parser is replaced on TLS upgrade
/// (XMPP "new stream" semantics) but `events` survives across resets.
actor XMPPConnection {
    private let transport: any XMPPTransport
    private var parser: XMPPStreamParser
    private var receiveTask: Task<Void, Never>?
    private(set) var isDirectTLS = false

    /// Whether the current parser has produced a TLS-namespace `<proceed/>`.
    private var hasSeenProceed = false
    /// Whether the current parser produced any event after `<proceed/>` or during a phase transition. A STARTTLS upgrade
    /// rejects it, since a compliant server sends nothing between `<proceed/>` and the TLS handshake.
    private var hasEventsAfterProceed = false
    /// Set from the start of a STARTTLS upgrade until its TLS stream starts receiving, so a failed upgrade leaves delivery
    /// halted until `disconnect()`. Also marks the plaintext stream's end as intentional.
    private var isTransitioningPhase = false

    private let eventContinuation: AsyncStream<XMLStreamEvent>.Continuation

    /// Unified event stream that survives parser resets across TLS upgrades.
    nonisolated let events: AsyncStream<XMLStreamEvent>

    init(transport: any XMPPTransport) {
        let (stream, continuation) = AsyncStream.makeStream(of: XMLStreamEvent.self)
        self.events = stream
        self.eventContinuation = continuation
        self.transport = transport
        self.parser = XMPPStreamParser()
    }

    // MARK: - Connecting

    /// SRV-aware connect: resolves SRV records and tries in priority order.
    func connect(domain: String) async throws {
        let records = await XMPPSRVLookup.resolve(domain: domain)
        var lastError: (any Error)?
        for record in records {
            do {
                if record.directTLS {
                    try await connectWithTLS(host: record.target, port: record.port, serverName: domain)
                } else {
                    try await connect(host: record.target, port: record.port)
                }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? XMPPClientError.connectionFailed("No SRV records available")
    }

    /// Direct connect to a specific host and port.
    func connect(host: String, port: UInt16) async throws {
        isDirectTLS = false
        try await transport.connect(host: host, port: port)
        startReceiving(from: transport.receivedData)
    }

    /// Direct TLS connect — TLS from the first byte, no STARTTLS upgrade.
    func connectWithTLS(host: String, port: UInt16, serverName: String) async throws {
        try await transport.connectWithTLS(host: host, port: port, serverName: serverName)
        isDirectTLS = true
        startReceiving(from: transport.receivedData)
    }

    // MARK: - TLS

    /// Ends the plaintext phase, then upgrades the transport to TLS and starts a fresh parser on the TLS stream.
    ///
    /// Event delivery halts first, and every plaintext chunk the transport read is drained through the old parser, so no
    /// plaintext reaches the post-TLS parser. Throws `tlsNegotiationFailed` before the handshake when the old parser
    /// produced anything after `<proceed/>`, even an event it already delivered. Plaintext still unread in the socket goes
    /// to the TLS handshake, which fails on it.
    func upgradeTLS(serverName: String) async throws {
        isTransitioningPhase = true
        let plaintextReceiveTask = receiveTask
        await transport.stopReceiving()
        await plaintextReceiveTask?.value
        closeParser()
        guard !hasEventsAfterProceed else {
            throw XMPPClientError.tlsNegotiationFailed("The server sent unexpected data after agreeing to start TLS")
        }

        let receivedData = try await transport.upgradeTLS(serverName: serverName)
        replaceParser()
        isTransitioningPhase = false
        startReceiving(from: receivedData)
    }

    /// STARTTLS callers upgrade only on this element, so the post-proceed record must recognize exactly the same one.
    static func isTLSProceed(_ element: XMLElement) -> Bool {
        element.name == "proceed" && element.namespace == XMPPNamespaces.tls
    }

    var tlsInfo: TLSInfo? {
        get async { await transport.tlsInfo }
    }

    var channelBindings: [ChannelBindingType: [UInt8]] {
        get async {
            await transport.channelBindings()
        }
    }

    // MARK: - Stream Reset

    /// Resets the parser for a new XMPP stream (e.g. after SASL). Receive task continues.
    func resetStream() {
        _ = parser.close()
        replaceParser()
    }

    // MARK: - Sending

    func send(_ bytes: [UInt8]) async throws {
        try await transport.send(bytes)
    }

    // MARK: - Disconnecting

    /// Sends the closing `</stream:stream>` tag only, reporting whether the write reached the transport. Callers
    /// own any wait for the server's matching close.
    func sendStreamClose() async -> Bool {
        do {
            try await transport.send(XMPPStreamWriter.streamClosing())
            return true
        } catch {
            return false
        }
    }

    /// Clean shutdown: stops tasks, closes parser, disconnects transport, finishes event stream.
    func disconnect() async {
        stopTasks()
        _ = parser.close()
        isDirectTLS = false
        await transport.disconnect()
        eventContinuation.finish()
    }

    private func startReceiving(from receivedData: AsyncStream<[UInt8]>) {
        receiveTask = Task { [weak self] in
            for await bytes in receivedData {
                await self?.feedParser(bytes)
            }
            if !Task.isCancelled {
                await self?.receivedDataEnded()
            }
        }
    }

    private func feedParser(_ bytes: [UInt8]) {
        deliver(parser.parse(bytes))
    }

    private func closeParser() {
        deliver(parser.close())
    }

    /// Yields parsed events outside a phase transition and records any that follow `<proceed/>` or arrive during one.
    private func deliver(_ events: [XMLStreamEvent]) {
        for event in events {
            if hasSeenProceed || isTransitioningPhase {
                hasEventsAfterProceed = true
            }
            guard !isTransitioningPhase else { continue }
            if case let .stanzaReceived(element) = event, Self.isTLSProceed(element) {
                hasSeenProceed = true
            }
            eventContinuation.yield(event)
        }
    }

    /// The receive stream ended without cancellation. Ending the plaintext phase for a STARTTLS upgrade finishes that
    /// stream on purpose, so only an end outside a transition closes the parser and finishes `events`.
    private func receivedDataEnded() {
        guard !isTransitioningPhase else { return }
        closeParser()
        eventContinuation.finish()
    }

    private func replaceParser() {
        parser = XMPPStreamParser()
        hasSeenProceed = false
        hasEventsAfterProceed = false
    }

    private func stopTasks() {
        receiveTask?.cancel()
        receiveTask = nil
    }
}
