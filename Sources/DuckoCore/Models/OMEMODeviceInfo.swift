import DuckoXMPP

public struct OMEMODeviceInfo: Sendable, Identifiable {
    public var id: String {
        "\(peerJID)-\(deviceID)"
    }

    public let peerJID: String
    public let deviceID: UInt32
    public let fingerprint: String
    public let trustLevel: OMEMOTrustLevel
    /// The OMEMO versions whose device list, as last fetched or notified, holds the device. Empty when neither list is
    /// known, as without a connection.
    public let versions: Set<OMEMOWireFormat>

    public init(peerJID: String, deviceID: UInt32, fingerprint: String, trustLevel: OMEMOTrustLevel, versions: Set<OMEMOWireFormat>) {
        self.peerJID = peerJID
        self.deviceID = deviceID
        self.fingerprint = fingerprint
        self.trustLevel = trustLevel
        self.versions = versions
    }

    /// Formats a stored fingerprint in the form the user compares: the Curve25519 key in eight groups of eight hex digits.
    public static func formatFingerprint(_ hex: String) -> String {
        omemoDisplayFingerprint(ofStoredFingerprint: hex)
    }
}
