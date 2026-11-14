/// A TLS channel-binding type, named as IANA registers it.
public enum ChannelBindingType: String, CaseIterable, Hashable, Sendable {
    /// RFC 9266, derived from the TLS 1.3 keying-material exporter.
    case tlsExporter = "tls-exporter"
    /// RFC 5929 §4.1, derived from the server certificate.
    case tlsServerEndPoint = "tls-server-end-point"

    /// Lower binds first when the server lists several types.
    var preferenceRank: Int {
        switch self {
        case .tlsExporter: 0
        case .tlsServerEndPoint: 1
        }
    }
}

/// Abstracts the network transport for testability.
public protocol XMPPTransport: Sendable {
    func connect(host: String, port: UInt16) async throws
    func connectWithTLS(host: String, port: UInt16, serverName: String) async throws

    /// Ends the current receive phase. No further bytes are yielded and the current receive stream finishes, so a consumer
    /// drains what is buffered and then ends. In-flight writes complete before it returns, so none overlaps a following
    /// TLS handshake.
    func stopReceiving() async

    /// Upgrades the connection to TLS in place and returns the TLS phase's receive stream. Requires a prior
    /// `stopReceiving()`.
    func upgradeTLS(serverName: String) async throws -> AsyncStream<[UInt8]>

    var tlsInfo: TLSInfo? { get async }

    /// Once accepted, bytes remain ordered even if the caller is cancelled: a stanza may already be counted for resumption.
    /// Completion is bounded by the write deadline or connection teardown.
    func send(_ bytes: [UInt8]) async throws

    /// The receive stream for the phase that `connect` or `connectWithTLS` starts.
    var receivedData: AsyncStream<[UInt8]> { get }

    /// Closes the connection and finishes whichever phase's receive stream is current.
    func disconnect() async

    /// The channel bindings computed for the current TLS connection, by type, and empty without TLS. A type whose value
    /// could not be computed is left out, never filled with a placeholder.
    func channelBindings() async -> [ChannelBindingType: [UInt8]]
}
