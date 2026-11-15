import DuckoXMPP
import Foundation

/// Filing the OMEMO messages this device receives, live and from carbons (XEP-0280), and reading archived ones.
extension OMEMOService {
    /// Files a live OMEMO message the module read, or could not read, and keeps the sessions it moved on. `roomAuthor`
    /// is who sent a room or room private message, as its outer stanza showed it.
    func handleEncryptedMessageReceived(_ message: XMPPMessage, outcome: OMEMOReceiveOutcome, roomAuthor: RoomAuthorIdentity?, accountID: UUID) async {
        let content = await encryptedContent(of: outcome, accountID: accountID)
        await chatService?.receiveEncryptedMessage(message, content: content, origin: .live, roomAuthor: roomAuthor, accountID: accountID)
        await saveSessions(accountID: accountID)
    }

    /// Takes a carbon whose forwarded message is encrypted: one another of the user's devices sent when `isOutgoing`,
    /// else one it received. Its message is filed in the chat with the carbon's peer, and one without an OMEMO payload
    /// shows a notice there. An error bounce is not filed, as the message it returns was not written for this device.
    /// Carbons are the only path that decrypts a forwarded message, so none is decrypted twice.
    func handleEncryptedCarbon(_ forwarded: ForwardedMessage, isOutgoing: Bool, accountID: UUID) async {
        guard forwarded.message.messageType != .error else { return }
        let origin = EncryptedMessageOrigin.carbon(isOutgoing: isOutgoing, sentTime: forwarded.sentTime)
        if let reason = forwarded.message.unreadableEncryption {
            await chatService?.receiveEncryptedMessage(forwarded.message, content: .undecryptable(reason), origin: origin, accountID: accountID)
            return
        }
        guard let module = await accountService?.client(for: accountID)?.module(ofType: OMEMOModule.self) else { return }
        if let outcome = module.receiveForwardedMessage(forwarded.message) {
            let content = await encryptedContent(of: outcome, accountID: accountID)
            await chatService?.receiveEncryptedMessage(forwarded.message, content: content, origin: origin, accountID: accountID)
        }
        await saveModuleSessions(module: module, accountID: accountID)
    }

    /// Decrypts `message`, an entry an archive returned (XEP-0313), and keeps the sessions it moved on. `sender` is the
    /// real JID the archive recorded for a room message's or room private message's author, and a key exchange is taken
    /// up only when `allowsKeyExchange`. Nil when the account's module is gone or the entry has nothing to show, such
    /// as one that only carries key material.
    func decryptArchivedMessage(
        _ message: XMPPMessage, sender: BareJID?, isRoomPrivateMessage: Bool, allowsKeyExchange: Bool, accountID: UUID
    ) async -> EncryptedContent? {
        guard let module = await accountService?.client(for: accountID)?.module(ofType: OMEMOModule.self) else { return nil }
        let outcome = module.receiveArchivedMessage(
            message, sender: sender, isRoomPrivateMessage: isRoomPrivateMessage, allowsKeyExchange: allowsKeyExchange
        )
        await saveModuleSessions(module: module, accountID: accountID)
        guard let outcome else { return nil }
        return await encryptedContent(of: outcome, accountID: accountID)
    }

    /// What `outcome` files as, with a decrypted message marked when its device is not trusted for encryption.
    private func encryptedContent(of outcome: OMEMOReceiveOutcome, accountID: UUID) async -> EncryptedContent {
        guard case let .decrypted(decrypted) = outcome else { return EncryptedContent(outcome) }
        let isTrusted = await isTrustedForEncryption(jid: decrypted.senderJID, deviceID: decrypted.senderDeviceID, accountID: accountID)
        return EncryptedContent(outcome, isFromUntrustedDevice: !isTrusted)
    }

    /// Saves the sessions of the account's client, connected or not, since stanzas the server replays after a resume
    /// arrive before the account counts as connected again.
    func saveSessions(accountID: UUID) async {
        guard let module = await accountService?.client(for: accountID)?.module(ofType: OMEMOModule.self) else { return }
        await saveModuleSessions(module: module, accountID: accountID)
    }
}
