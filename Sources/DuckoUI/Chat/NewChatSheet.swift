import DuckoCore
import SwiftUI

struct NewChatSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    var onStartChat: (String, UUID?) -> Void
    @State private var jidString = ""
    @State private var selectedAccountID: UUID?
    @State private var errorMessage: String?

    /// Only enabled accounts can send, so the picker offers (and defaults to) those. Shown only when more than one
    /// exists.
    private var enabledAccounts: [Account] {
        environment.accountService.enabledAccounts
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("New Chat")
                .font(.headline)

            TextField("JID (e.g. bob@example.com)", text: $jidString)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("new-chat-jid-field")

            if enabledAccounts.count > 1 {
                Picker("Account", selection: $selectedAccountID) {
                    ForEach(enabledAccounts) { account in
                        Text(account.displayName ?? account.jid.description).tag(account.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("new-chat-account-picker")
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityIdentifier("new-chat-error")
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Start Chat") {
                    startChat()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(jidString.isEmpty)
                .accessibilityIdentifier("start-chat-button")
            }
        }
        .padding(20)
        .frame(minWidth: 350)
        .onAppear {
            if selectedAccountID == nil {
                selectedAccountID = enabledAccounts.first?.id
            }
        }
    }

    private func startChat() {
        let trimmed = jidString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard JIDValidation.isValidUserOrRoomJID(trimmed) else {
            errorMessage = "Invalid JID: \(trimmed)"
            return
        }
        errorMessage = nil
        onStartChat(trimmed, selectedAccountID)
        dismiss()
    }
}
