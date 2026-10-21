/// Errors from XMPP client operations.
public enum XMPPClientError: Error {
    case notConnected
    case alreadyConnected
    case connectionFailed(String)
    case sendFailed(String)
    case tlsRequired
    case tlsNegotiationFailed(String)
    case authenticationFailed(String)
    /// Sign-in requires SCRAM, and the server offered only PLAIN, so the password was not sent.
    case plainSignInRefused
    case bindingFailed(String)
    case sessionFailed(String)
    case unexpectedStreamState(String)
    case timeout
    case streamManagementBusy
    /// The configured domain could not be converted to an A-label for DNS/TLS lookup.
    case invalidDomain(String)
}
