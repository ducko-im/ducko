/// Builder for configuring and creating an ``XMPPClient``.
public struct XMPPClientBuilder {
    private let domain: String
    private let credentials: XMPPClient.Credentials
    private var transport: (any XMPPTransport)?
    private var interceptors: [any StanzaInterceptor] = []
    private var modules: [any XMPPModule] = []
    private var requireTLS: Bool = true
    private var requiresSCRAM = false
    private var preferredResource: String?
    private var userAgent = SASL2UserAgent()

    public init(domain: String, username: String, password: String) {
        self.domain = domain
        self.credentials = XMPPClient.Credentials(username: username, password: password)
    }

    /// Sets whether TLS is required (default: `true`).
    public mutating func withRequireTLS(_ requireTLS: Bool) {
        self.requireTLS = requireTLS
    }

    /// Sets whether a sign-in that offers only PLAIN is refused before the password is sent (default: `false`).
    public mutating func withRequiresSCRAM(_ requiresSCRAM: Bool) {
        self.requiresSCRAM = requiresSCRAM
    }

    /// Sets a preferred resource for binding. Server may ignore it.
    public mutating func withPreferredResource(_ resource: String?) {
        preferredResource = resource
    }

    /// Sets the user agent a SASL2 sign-in names.
    public mutating func withUserAgent(_ userAgent: SASL2UserAgent) {
        self.userAgent = userAgent
    }

    /// Sets a custom transport (e.g. for testing with ``MockTransport``).
    public mutating func withTransport(_ transport: any XMPPTransport) {
        self.transport = transport
    }

    public mutating func withInterceptor(_ interceptor: any StanzaInterceptor) {
        interceptors.append(interceptor)
    }

    public mutating func withModule(_ module: any XMPPModule) {
        modules.append(module)
    }

    /// `async` because ``XMPPClient/register(_:)`` is actor-isolated.
    public func build() async -> XMPPClient {
        let client = XMPPClient(
            domain: domain,
            credentials: credentials,
            transport: transport,
            requireTLS: requireTLS,
            requiresSCRAM: requiresSCRAM,
            preferredResource: preferredResource,
            userAgent: userAgent
        )

        for interceptor in interceptors {
            await client.addInterceptor(interceptor)
        }

        for module in modules {
            await client.register(module)
        }

        return client
    }
}
