/// Why the server's certificate was not trusted.
public enum CertificateTrustFailure: Sendable, Equatable {
    /// The certificate names another server.
    case nameMismatch
    /// The certificate has expired or is not valid yet.
    case outsideValidityPeriod
    /// Any other reason, most often a chain that leads to no trusted authority.
    case notTrusted

    public var displayText: String {
        switch self {
        case .nameMismatch: "Issued for a different server"
        case .outsideValidityPeriod: "Expired or not valid yet"
        case .notTrusted: "Not signed by a trusted authority"
        }
    }
}
