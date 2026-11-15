/// What a reset of the encryption sessions with a contact, or with the account's other devices, did with each device.
public struct OMEMOSessionResetReport: Sendable, Equatable {
    public struct Device: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            /// A new session was built and announced to the device. `needsTrusting` is true when the device is not
            /// trusted for encryption, so messages reach it only once the user trusts it.
            case rebuilt(needsTrusting: Bool)
            /// The device is marked untrusted, so its session was only discarded.
            case discarded
            /// The device's key changed, so its session was discarded and the device is untrusted under the new key
            /// until the user trusts it. Both fingerprints are in the stored form. `previousFingerprint` is empty when
            /// the old key could not be read.
            case keyChanged(previousFingerprint: String, newFingerprint: String)
            /// The device publishes no usable keys, so its session was only discarded.
            case noBundle
            /// The device is not on the current device list, so its session was only discarded.
            case notListed
            /// The reset failed for the device, for the reason given.
            case failed(String)
        }

        public let deviceID: UInt32
        public let outcome: Outcome

        public init(deviceID: UInt32, outcome: Outcome) {
            self.deviceID = deviceID
            self.outcome = outcome
        }

        /// What the reset did with the device, as the chat and the CLI show it.
        public var summary: String {
            switch outcome {
            case let .rebuilt(needsTrusting):
                "Device \(deviceID) has a new session" + (needsTrusting ? " and needs trusting" : "")
            case .discarded:
                "Device \(deviceID) is marked untrusted, so its session was discarded"
            case let .keyChanged(previousFingerprint, newFingerprint):
                "Device \(deviceID) changed its key"
                    + (previousFingerprint.isEmpty ? "" : " from \(OMEMODeviceInfo.formatFingerprint(previousFingerprint))")
                    + " to \(OMEMODeviceInfo.formatFingerprint(newFingerprint)) and needs trusting"
            case .noBundle:
                "Device \(deviceID) publishes no keys, so its session was discarded"
            case .notListed:
                "Device \(deviceID) is not on the device list, so its session was discarded"
            case let .failed(reason):
                "Device \(deviceID) could not be reset: \(reason)"
            }
        }

        /// Whether the user has to act on the device: trust it, or reset it again.
        public var needsAttention: Bool {
            switch outcome {
            case let .rebuilt(needsTrusting): needsTrusting
            case .noBundle, .notListed: false
            case .discarded, .keyChanged, .failed: true
            }
        }
    }

    /// The bare JID of the contact, or of the account for its other devices.
    public let peerJID: String
    public let devices: [Device]

    public init(peerJID: String, devices: [Device]) {
        self.peerJID = peerJID
        self.devices = devices
    }

    /// What the chat's note adds about the devices that need the user's attention, or nil when none does.
    var noteDetail: String? {
        let summaries = devices.filter(\.needsAttention).map(\.summary)
        return summaries.isEmpty ? nil : summaries.joined(separator: ". ")
    }
}
