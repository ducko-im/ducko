import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.omemo")

/// Resetting the encryption sessions with a contact's devices or the account's other devices, for when their messages
/// cannot be decrypted (XEP-0384).
extension OMEMOService {
    /// Resets the session with `peerJID`'s device `deviceID`, or with every device on its current list when it is nil.
    /// For the account's own JID this device is left out, and naming it throws. The stored trust is taken in first, so
    /// a decision another process made counts. A trusted or undecided device gets a new session and an empty key
    /// exchange. A device marked untrusted only has its session discarded, as does a named device that is not on the
    /// list. A device whose key changed is marked untrusted under the new key. A device the reset fails for is reported
    /// as failed, and the others still go on. The chat with a contact notes the result.
    public func resetSessions(peerJID: String, deviceID: UInt32?, accountID: UUID) async throws -> OMEMOSessionResetReport {
        guard let peer = BareJID.parse(peerJID) else { throw ChatService.ChatServiceError.invalidJID(peerJID) }
        guard let client = accountService?.connectedClient(for: accountID), let accountJID = accountJIDString(for: accountID) else {
            throw OMEMOServiceError.notConnected(accountID)
        }
        guard let module = await client.module(ofType: OMEMOModule.self) else { throw OMEMOServiceError.omemoNotAvailable }
        // Another process may have stored a trust decision the guard has not taken in, such as an untrust from the CLI.
        _ = await loadAllDevicesMergingTrust(for: peer.description, accountJID: accountJID)
        let isOwn = peer.description == accountJID
        let thisDeviceID = isOwn ? module.ownDeviceID : nil
        if let deviceID, deviceID == thisDeviceID { throw OMEMOServiceError.thisDeviceNotResettable }
        let listed = try await module.fetchDeviceList(for: peer, forceRefresh: true)
        let deviceIDs = deviceID.map { [$0] } ?? listed.filter { $0 != thisDeviceID }
        var devices: [OMEMOSessionResetReport.Device] = []
        for deviceID in deviceIDs {
            let outcome: OMEMOSessionResetReport.Device.Outcome
            do {
                if listed.contains(deviceID) {
                    outcome = try await resetSession(with: peer, deviceID: deviceID, module: module, accountID: accountID, accountJID: accountJID)
                } else {
                    module.discardSession(jid: peer, deviceID: deviceID)
                    try await omemoStore.deleteSession(accountJID: accountJID, peerJID: peer.description, peerDeviceID: deviceID)
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

    /// Resets one device's session in the module, then brings the store in line: a new session is saved, a discarded one
    /// deleted. A changed key is held and stored as untrusted before the session is deleted, so the device stays refused
    /// even when a store write fails.
    private func resetSession(
        with peer: BareJID, deviceID: UInt32, module: OMEMOModule, accountID: UUID, accountJID: String
    ) async throws -> OMEMOSessionResetReport.Device.Outcome {
        let outcome: OMEMOSessionResetReport.Device.Outcome
        switch try await module.resetSession(jid: peer, deviceID: deviceID) {
        case .rebuilt:
            await saveModuleSessions(module: module, accountID: accountID)
            return await .rebuilt(needsTrusting: !isTrustedForEncryption(jid: peer, deviceID: deviceID, accountID: accountID))
        case .discarded:
            outcome = .discarded
        case let .keyChanged(previousFingerprint, newIdentityKey):
            let newFingerprint = omemoFingerprint(of: newIdentityKey)
            let trustGuard = trustGuard(forAccountJID: accountJID)
            let decision = trustGuard.replaceHeldKey(peer: peer, deviceID: deviceID, fingerprint: newFingerprint)
            try await omemoStore.saveTrust(OMEMOTrust(
                accountJID: accountJID, peerJID: peer.description, deviceID: deviceID, fingerprint: newFingerprint, trustLevel: .untrusted
            ))
            trustGuard.distrustSaved(peer: peer, deviceID: deviceID, decision: decision)
            outcome = .keyChanged(previousFingerprint: previousFingerprint, newFingerprint: newFingerprint)
        case .noBundle:
            outcome = .noBundle
        }
        try await omemoStore.deleteSession(accountJID: accountJID, peerJID: peer.description, peerDeviceID: deviceID)
        return outcome
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
