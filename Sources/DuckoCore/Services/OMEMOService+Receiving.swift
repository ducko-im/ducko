import DuckoXMPP
import Foundation

/// Filing the OMEMO messages this device receives, live and from carbons (XEP-0280).
extension OMEMOService {
    /// Files a live OMEMO message the module read, or could not read, and keeps the sessions it moved on.
    func handleEncryptedMessageReceived(_ message: XMPPMessage, outcome: OMEMOReceiveOutcome, accountID: UUID) async {
        await chatService?.receiveEncryptedMessage(message, content: EncryptedContent(outcome), origin: .live, accountID: accountID)
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
            await chatService?.receiveEncryptedMessage(forwarded.message, content: EncryptedContent(outcome), origin: origin, accountID: accountID)
        }
        await saveModuleSessions(module: module, accountID: accountID)
    }

    /// Saves the sessions of the account's client, connected or not, since stanzas the server replays after a resume
    /// arrive before the account counts as connected again.
    func saveSessions(accountID: UUID) async {
        guard let module = await accountService?.client(for: accountID)?.module(ofType: OMEMOModule.self) else { return }
        await saveModuleSessions(module: module, accountID: accountID)
    }
}
