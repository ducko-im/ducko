/// Errors from XMPP client operations.
public enum XMPPClientError: Error {
    case notConnected
    case alreadyConnected
    case connectionFailed(String)
    case sendFailed(String)
    case tlsRequired
    case tlsNegotiationFailed(String)
    /// Ducko did not trust the server's certificate, so the connection was not used.
    case untrustedCertificate(CertificateTrustFailure)
    case authenticationFailed(AuthenticationFailure)
    /// Sign-in requires SCRAM, and the server offered only PLAIN, so the password was not sent.
    case plainSignInRefused
    case bindingFailed(String)
    case sessionFailed(String)
    case unexpectedStreamState(String)
    /// A step after sign-in, such as fetching the roster or sending presence, failed with the error it carries, so the
    /// session was ended.
    case sessionSetupFailed(any Error)
    case timeout
    case streamManagementBusy
    /// The configured domain could not be converted to an A-label for DNS/TLS lookup.
    case invalidDomain(String)
}
