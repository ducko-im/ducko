import DuckoCore
import SwiftUI

/// Invites a JID to a room. Presented from the room's context menu via
/// `ContactListView`'s `.sheet(item:)`.
struct InviteUserSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @State private var jidString = ""
    @State private var reason = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Invite User")
                .font(.headline)

            TextField("JID (e.g. bob@example.com)", text: $jidString)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("invite-user-jid-field")

            TextField("Reason (optional)", text: $reason)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("invite-user-reason-field")

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityIdentifier("invite-user-error")
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Invite") {
                    inviteUser()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(jidString.isEmpty)
                .accessibilityIdentifier("invite-user-button")
            }
        }
        .padding(20)
        .frame(minWidth: 350)
    }

    private func inviteUser() {
        let trimmed = jidString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard JIDValidation.isValidUserOrRoomJID(trimmed) else {
            errorMessage = "Invalid JID: \(trimmed)"
            return
        }
        errorMessage = nil
        let reasonText = reason.isEmpty ? nil : reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accountID = conversation.accountID else { return }
        Task {
            do {
                try await environment.chatService.inviteUser(
                    jidString: trimmed,
                    toRoomJIDString: conversation.jid.description,
                    reason: reasonText,
                    accountID: accountID
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
