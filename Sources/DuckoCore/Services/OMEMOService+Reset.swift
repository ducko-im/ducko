import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.omemo")

/// Resetting the encryption sessions with a contact's devices or the account's other devices, for when their messages
/// cannot be decrypted (XEP-0384).
extension OMEMOService {
    /// Resets the sessions with `peerJID`'s device `deviceID`, or with every device on either of its current lists when
    /// it is nil, in each version whose list holds the device. For the account's own JID this device is left out, and
    /// naming it throws. The stored trust is taken in first, so a decision another process made counts. A trusted or
    /// undecided device gets a new session and an empty key exchange. A device marked untrusted only has its sessions
    /// discarded, as does a named device that is on neither list. A device whose key changed in every version that
    /// carries a key is marked untrusted under the new key. A device the reset fails for is reported as failed, and the
    /// others still go on. The chat with a contact notes the result.
    public func resetSessions(peerJID: String, deviceID: UInt32?, accountID: UUID) async throws -> OMEMOSessionResetReport {
        guard let peer = BareJID.parse(peerJID) else { throw ChatService.ChatServiceError.invalidJID(peerJID) }
        guard let client = accountService?.connectedClient(for: accountID), let accountJID = accountJIDString(for: accountID) else {
            throw OMEMOServiceError.notConnected(accountID)
        }
        guard let module = await client.module(ofType: OMEMOModule.self) else { throw OMEMOServiceError.omemoNotAvailable }
        await module.awaitIdentityIfSettingUp()
        guard let ownDeviceID = module.ownDeviceID else { throw OMEMOServiceError.encryptionNotSetUp }
        // Another process may have stored a trust decision the guard has not taken in, such as an untrust from the CLI.
        _ = await loadAllDevicesMergingTrust(for: peer.description, accountJID: accountJID)
        let isOwn = peer.description == accountJID
        let thisDeviceID = isOwn ? ownDeviceID : nil
        if let deviceID, deviceID == thisDeviceID { throw OMEMOServiceError.thisDeviceNotResettable }
        let listed = try await freshlyListedDevices(of: peer, module: module)
        let deviceIDs: [UInt32] = deviceID.map { [$0] } ?? listed.map(\.deviceID).filter { $0 != thisDeviceID }
        var devices: [OMEMOSessionResetReport.Device] = []
        for deviceID in deviceIDs {
            let outcome: OMEMOSessionResetReport.Device.Outcome
            do {
                if let device = listed.first(where: { $0.deviceID == deviceID }) {
                    outcome = try await resetSessions(of: device, with: peer, module: module, accountID: accountID, accountJID: accountJID)
                } else {
                    let reset = try await module.resetSession(jid: peer, deviceID: deviceID, versions: [])
                    try await storeKnownKey(reset.knownFingerprint, of: deviceID, with: peer, module: module, accountJID: accountJID)
                    try await storeSessions(of: deviceID, with: peer, after: reset, module: module, accountJID: accountJID)
                    outcome = .notListed
                }
            } catch {
                log.warning("An OMEMO session could not be reset")
                log.debug("The OMEMO session with \(peer) device \(deviceID) could not be reset: \(error)")
                outcome = .failed(error.localizedDescription)
            }
            devices.append(OMEMOSessionResetReport.Device(deviceID: deviceID, outcome: outcome))
        }
        let report = OMEMOSessionResetReport(peerJID: peer.description, devices: devices)
        if !isOwn {
            await noteSessionsReset(report, with: peer, accountID: accountID)
        }
        return report
    }

    /// Resets one device's sessions in its versions in the module, then brings the store in line with what the reset
    /// did, also when it failed for a version. A failure before the reset discarded anything stores nothing, and the
    /// store writes stop once the module lost its identity, as a disconnect leaves it.
    ///
    /// The device's first changed key, in the order of its versions, replaces the known one only when no version still
    /// carries the known one. It is then held and stored as untrusted before the sessions are deleted, so the device
    /// stays refused even when a store write fails. Otherwise the known key is stored before the sessions that may have
    /// been its only record are deleted, and a stored row naming another key fails the device, deleting nothing. While
    /// a rebuilt version carries the known key, the changed key is reported as refused beside the new session.
    private func resetSessions(
        of device: ListedDevice, with peer: BareJID, module: OMEMOModule, accountID: UUID, accountJID: String
    ) async throws -> OMEMOSessionResetReport.Device.Outcome {
        let deviceID = device.deviceID
        let versions = device.versions
        let reset = try await module.resetSession(jid: peer, deviceID: deviceID, versions: versions)
        let outcomes = reset.outcomes
        let rebuilt = versions.filter { outcomes[$0] == .rebuilt }
        let changedKey = versions.lazy.compactMap { version -> (previous: String, new: String)? in
            if case let .keyChanged(previous, new)? = outcomes[version] { (previous, new) } else { nil }
        }.first
        let outcome: OMEMOSessionResetReport.Device.Outcome
        if let changedKey, !reset.carriesKnownKey {
            try requireIdentity(of: module)
            let trustGuard = trustGuard(forAccountJID: accountJID)
            let decision = trustGuard.replaceHeldKey(peer: peer, deviceID: deviceID, fingerprint: changedKey.new)
            try await omemoStore.saveTrust(OMEMOTrust(
                accountJID: accountJID, peerJID: peer.description, deviceID: deviceID, fingerprint: changedKey.new, trustLevel: .untrusted
            ))
            trustGuard.distrustSaved(peer: peer, deviceID: deviceID, decision: decision)
            outcome = .keyChanged(previousFingerprint: changedKey.previous, newFingerprint: changedKey.new)
        } else {
            try await storeKnownKey(reset.knownFingerprint, of: deviceID, with: peer, module: module, accountJID: accountJID)
            if !rebuilt.isEmpty {
                let needsTrusting = await !isTrustedForEncryption(jid: peer, deviceID: deviceID, accountID: accountID)
                outcome = if let changedKey {
                    .rebuiltKeyRefused(needsTrusting: needsTrusting, newFingerprint: changedKey.new)
                } else {
                    .rebuilt(needsTrusting: needsTrusting)
                }
            } else if outcomes.values.contains(.discarded) {
                outcome = .discarded
            } else {
                outcome = .noBundle
            }
        }
        try await storeSessions(of: deviceID, with: peer, after: reset, module: module, accountJID: accountJID)
        if let failure = reset.failure { throw failure }
        return outcome
    }

    /// Fills the device's trust row with `fingerprint`, the key it is known by, keeping the row's trust level, so the key
    /// outlasts the sessions a reset deletes. An empty one stores nothing. Throws `conflictingFingerprints` when the row
    /// names another key, as another process over the same store can have stored, so the reset deletes nothing.
    private func storeKnownKey(
        _ fingerprint: String, of deviceID: UInt32, with peer: BareJID, module: OMEMOModule, accountJID: String
    ) async throws {
        try requireIdentity(of: module)
        guard !fingerprint.isEmpty else { return }
        let stored = try await omemoStore.fillTrustFingerprint(accountJID: accountJID, peerJID: peer.description, deviceID: deviceID, fingerprint: fingerprint)
        if stored != nil {
            log.warning("Identity key changed for device \(deviceID)")
            log.debug("The changed identity key belongs to \(peer)")
            throw OMEMOServiceError.conflictingFingerprints
        }
    }

    /// Saves the module's session with `peer`'s device `deviceID` in each version the reset replaced, as the other
    /// session saves do, and deletes the stored one of each other version the module holds no session in. A version the
    /// module holds a session in again, as from a key exchange meanwhile, keeps it, and a replaced one the module no
    /// longer holds is left as stored. Throws `notSetUp`, changing nothing more, once the module lost its identity, as a
    /// disconnect leaves it. Each version's session is read under one lock with that identity.
    private func storeSessions(
        of deviceID: UInt32, with peer: BareJID, after reset: SessionReset, module: OMEMOModule, accountJID: String
    ) async throws {
        for version in OMEMOWireFormat.allCases {
            let entry = try module.exportSessionRequiringIdentity(jid: peer, deviceID: deviceID, version: version)
            if reset.replacedVersions.contains(version) {
                guard let entry else { continue }
                await saveSession(entry, accountJID: accountJID)
            } else if entry == nil {
                try await omemoStore.deleteSession(accountJID: accountJID, peerJID: peer.description, peerDeviceID: deviceID, version: version)
            }
        }
    }

    /// Throws `notSetUp`, so the reset writes no trust, once the module lost its identity, as a disconnect leaves it.
    private func requireIdentity(of module: OMEMOModule) throws {
        guard module.ownDeviceID != nil else { throw OMEMOModuleError.notSetUp }
    }

    /// A device on either of a JID's lists, with the versions whose list holds it, OMEMO 2 first.
    private struct ListedDevice {
        let deviceID: UInt32
        let versions: [OMEMOWireFormat]
    }

    /// The devices on either of `peer`'s lists, fetched afresh, OMEMO 2 ones first. A device a notification took off both
    /// lists meanwhile is left out.
    private func freshlyListedDevices(of peer: BareJID, module: OMEMOModule) async throws -> [ListedDevice] {
        let deviceIDs = try await module.fetchListedDevices(of: peer, forceRefresh: true)
        let listedVersions = module.listedVersions(of: peer)
        return deviceIDs.compactMap { deviceID in
            let versions = OMEMOWireFormat.allCases.filter { listedVersions[deviceID]?.contains($0) == true }
            return versions.isEmpty ? nil : ListedDevice(deviceID: deviceID, versions: versions)
        }
    }

    /// Leaves a note in the chat with `peer` that lists the devices needing the user's attention.
    private func noteSessionsReset(_ report: OMEMOSessionResetReport, with peer: BareJID, accountID: UUID) async {
        guard let chatService, !report.devices.isEmpty else { return }
        do {
            let conversation = try await chatService.openConversation(for: peer, accountID: accountID)
            try await chatService.transcripts.appendNote(TimelineNote(conversationID: conversation.id, kind: .sessionsReset, detail: report.noteDetail))
            chatService.bumpRevision(for: conversation.id)
        } catch {
            log.warning("Could not note the reset of encryption sessions")
            log.debug("Could not note the reset of encryption sessions: \(error)")
        }
    }
}
