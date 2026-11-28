import DuckoCore
import Foundation

/// The lines listing the devices of `jid`, one per device, or the empty result when it has none.
func omemoDeviceLines(jid: String, accountID: UUID, environment: AppEnvironment, formatter: any CLIFormatter) async -> [String] {
    let devices = await environment.omemoService.deviceInfoList(for: jid, accountID: accountID)
    guard !devices.isEmpty else { return [formatter.formatEmptyResult(.omemoDevices(jid: jid, accountID: accountID))] }
    return devices.map(formatter.formatOMEMODevice)
}

/// The contact's device with `deviceID` as the device list shows it.
func omemoDevice(jid: String, deviceID: UInt32, accountID: UUID, environment: AppEnvironment) async throws -> OMEMODeviceInfo {
    let devices = await environment.omemoService.deviceInfoList(for: jid, accountID: accountID)
    guard let device = devices.first(where: { $0.deviceID == deviceID }) else {
        throw CLIError.omemoDeviceNotFound(deviceID: deviceID, jid: jid)
    }
    return device
}

/// Marks the contact's device verified when `fingerprint` names its key. A device with no known key skips the match,
/// so that `verifyDevice` refuses it with its own error.
func verifyOMEMODevice(jid: String, deviceID: UInt32, fingerprint: String, accountID: UUID, environment: AppEnvironment) async throws {
    let device = try await omemoDevice(jid: jid, deviceID: deviceID, accountID: accountID, environment: environment)
    guard device.fingerprint.isEmpty || device.matchesFingerprint(fingerprint) else {
        throw CLIError.omemoFingerprintMismatch(deviceID: deviceID, jid: jid)
    }
    try await environment.omemoService.verifyDevice(
        accountID: accountID, peerJID: jid, deviceID: deviceID, fingerprint: device.fingerprint
    )
}

extension OMEMODeviceInfo {
    /// Whether `typed` is the device's key in its displayed or stored form, ignoring case and whitespace.
    func matchesFingerprint(_ typed: String) -> Bool {
        let candidate = Self.compacted(typed)
        let displayed = Self.compacted(Self.formatFingerprint(fingerprint))
        let stored = Self.compacted(fingerprint)
        return candidate == displayed || candidate == stored
    }

    private static func compacted(_ fingerprint: String) -> String {
        fingerprint.filter { !$0.isWhitespace }.lowercased()
    }
}
