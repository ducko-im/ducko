import Foundation

/// Information about the active TLS connection.
public struct TLSInfo: Sendable {
    public let protocolVersion: String
    /// The negotiated version's wire code, such as 0x0304 for TLS 1.3.
    public let wireVersion: UInt16?
    public let cipherSuite: String?
    public let certificateSubject: String?
    public let certificateIssuer: String?
    public let certificateExpiry: Date?
    public let certificateSHA256: String?

    public init(
        protocolVersion: String,
        wireVersion: UInt16? = nil,
        cipherSuite: String?,
        certificateSubject: String? = nil,
        certificateIssuer: String? = nil,
        certificateExpiry: Date? = nil,
        certificateSHA256: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.wireVersion = wireVersion
        self.cipherSuite = cipherSuite
        self.certificateSubject = certificateSubject
        self.certificateIssuer = certificateIssuer
        self.certificateExpiry = certificateExpiry
        self.certificateSHA256 = certificateSHA256
    }
}
