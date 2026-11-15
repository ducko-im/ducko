import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.omemo")

/// Who a message is encrypted to: the devices on each recipient's device list, as last fetched or notified, that the
/// trust store allows (XEP-0384).
extension OMEMOService {
    /// Resolution from `shouldEncrypt`. Callers fail closed on every case but `.proceed` and `.userDisabled` when the
    /// conversation has encryption enabled.
    public enum EncryptionResolution: Sendable {
        /// Encryption authorized for these recipient device IDs. Never empty, since no trusted device resolves to
        /// `.noTrustedDevicesForPeer`.
        case proceed(trustedDeviceIDs: [UInt32])
        /// Conversation has encryption disabled by the user, so plaintext is intentional.
        case userDisabled
        /// No device on the peer's device list has a trust row: the peer has no OMEMO, or lists no devices.
        case noLocalDevicesForPeer
        /// The peer lists devices, but none of them is trusted.
        case noTrustedDevicesForPeer
        /// The peer's device list could not be read, so the devices to encrypt to are unknown.
        case deviceListUnavailable
        /// Service not wired (tests only; production wires at app start). Distinct from `.proceed` so callers throw
        /// `omemoServiceUnavailable` without a nil check.
        case serviceUnavailable
    }

    /// Resolves encryption for a send to `jid`.
    func shouldEncrypt(jid: BareJID, accountID: UUID, conversationEncryptionEnabled: Bool) async -> EncryptionResolution {
        guard conversationEncryptionEnabled else { return .userDisabled }
        guard let accountJID = accountJIDString(for: accountID) else {
            return .noLocalDevicesForPeer
        }
        let listed: [OMEMOTrust]
        do {
            listed = try await listedDevices(of: jid, accountID: accountID, accountJID: accountJID)
        } catch {
            return .deviceListUnavailable
        }
        if listed.isEmpty {
            return .noLocalDevicesForPeer
        }
        let tofu = trustOnFirstUse()
        let trusted = listed.filter { $0.trustLevel.isTrustedForEncryption(trustOnFirstUse: tofu) }.map(\.deviceID)
        if trusted.isEmpty {
            return .noTrustedDevicesForPeer
        }
        return .proceed(trustedDeviceIDs: trusted)
    }

    /// The devices on `jid`'s device list as last fetched or notified, fetched when none or an empty one is cached. A
    /// missing list counts as empty. Each listed device without a trust row gets an undecided one, so it counts under
    /// trust on first use at once.
    func currentDeviceIDs(for jid: BareJID, accountID: UUID) async throws -> Set<UInt32> {
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw OMEMOServiceError.notConnected(accountID)
        }
        guard let omemoModule = await client.module(ofType: OMEMOModule.self) else {
            throw OMEMOServiceError.omemoNotAvailable
        }
        let devices = try await omemoModule.fetchDeviceList(for: jid)
        await seedUndecidedTrust(for: jid, devices: devices, accountID: accountID)
        return Set(devices)
    }

    /// The account's other devices are trusted like a contact's, so with trust on first use off a new one receives
    /// nothing until the user trusts it. None when the account's own list cannot be read: the message then misses the
    /// user's other devices, which discloses nothing, rather than failing every send.
    func trustedOwnDeviceIDs(accountID: UUID) async -> [UInt32] {
        guard let accountJID = accountJIDString(for: accountID), let ownJID = BareJID.parse(accountJID) else { return [] }
        do {
            let tofu = trustOnFirstUse()
            return try await listedDevices(of: ownJID, accountID: accountID, accountJID: accountJID)
                .filter { $0.trustLevel.isTrustedForEncryption(trustOnFirstUse: tofu) }.map(\.deviceID)
        } catch {
            log.warning("OMEMO own device list could not be read; encrypting to none of the account's other devices")
            log.debug("OMEMO own device list could not be read: \(error)")
            return []
        }
    }

    /// Whether `jid`'s device `deviceID` counts as trusted for encryption, as a send to it would count it. A device
    /// without a trust row counts as undecided, and one the account's trust guard refuses is not trusted whatever its
    /// stored row says, as after a distrust whose save failed.
    func isTrustedForEncryption(jid: BareJID, deviceID: UInt32, accountID: UUID) async -> Bool {
        guard let accountJID = accountJIDString(for: accountID) else { return false }
        let rows = await loadAllDevicesMergingTrust(for: jid.description, accountJID: accountJID)
        guard !trustGuard(forAccountJID: accountJID).refuses(peer: jid, deviceID: deviceID) else { return false }
        let level = rows.first { $0.deviceID == deviceID }?.trustLevel ?? .undecided
        return level.isTrustedForEncryption(trustOnFirstUse: trustOnFirstUse())
    }

    /// `peer`'s stored trust rows for the devices on its current list. The guard takes in the stored rows before the
    /// list is read, so another process's decisions reach it even when the list cannot be read, and again once the list
    /// has seeded rows for newly listed devices.
    func listedDevices(of peer: BareJID, accountID: UUID, accountJID: String) async throws -> [OMEMOTrust] {
        _ = await loadAllDevicesMergingTrust(for: peer.description, accountJID: accountJID)
        let listed = try await currentDeviceIDs(for: peer, accountID: accountID)
        return await loadAllDevicesMergingTrust(for: peer.description, accountJID: accountJID).filter { listed.contains($0.deviceID) }
    }
}
