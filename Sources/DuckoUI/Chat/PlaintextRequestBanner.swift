import DuckoCore
import SwiftUI

/// Visible while a contact's request for unencrypted messages blocks the last send. "Send Unencrypted" switches
/// encryption off and sends the blocked text. Dismiss leaves encryption on and the text in the composer.
struct PlaintextRequestBanner: View {
    @Bindable var windowState: ChatWindowState

    var body: some View {
        if let request = windowState.plaintextRequest {
            // In a chat with one contact the requester is the contact's address, so the chat's name stands in for it.
            let requester = windowState.isGroupchat ? request.requester : windowState.displayName
            DismissibleBanner(
                message: PlaintextRequest.summary(requester: requester, reason: request.reason),
                symbol: "lock.open.fill",
                alignment: .firstTextBaseline,
                dismissalLabel: "Dismiss notice"
            ) {
                windowState.clearSendError()
            } accessory: {
                if windowState.offersSendUnencrypted {
                    Button("Send Unencrypted") {
                        Task { await windowState.confirmPlaintextAndSend() }
                    }
                    .accessibilityIdentifier("send-unencrypted-button")
                }
            }
        }
    }
}
