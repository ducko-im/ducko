import DuckoCore
import SwiftUI

struct RoomInviteBanner: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var isEditingNickname: Bool
    @FocusState private var focusedInviteID: PendingRoomInvite.ID?

    var body: some View {
        let invites = environment.chatService.pendingInvites
        VStack(spacing: 0) {
            if !invites.isEmpty {
                VStack(spacing: 4) {
                    ForEach(invites) { invite in
                        RoomInviteRow(invite: invite, focusedInviteID: $focusedInviteID)
                    }
                }
                .padding(.vertical, 4)
                .background(Palette.accent.opacity(0.1))
                .accessibilityIdentifier("room-invite-banner")
            }
        }
        // On a container that outlives the `if`, so the last invite going away while its field is focused still
        // clears the flag.
        .onChange(of: focusedInviteID) {
            isEditingNickname = focusedInviteID != nil
        }
    }
}

private struct RoomInviteRow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openChat) private var openChat
    let invite: PendingRoomInvite
    var focusedInviteID: FocusState<PendingRoomInvite.ID?>.Binding
    @State private var nickname = ""
    @State private var errorMessage: String?

    /// The account the invite arrived on — drives accept/decline and the default nickname, so the
    /// same room invite on two accounts targets the right one rather than re-deriving `accounts.first`.
    private var account: Account? {
        environment.accountService.accounts.first { $0.id == invite.accountID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Room invitation: \(invite.roomJIDString)")
                        .font(.callout)
                        .singleLine()

                    if let from = invite.fromJIDString {
                        Text("From: \(from)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let reason = invite.reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()
            }

            HStack {
                TextField("Nickname", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
                    .focused(focusedInviteID, equals: invite.id)

                Spacer()

                Button("Accept") {
                    accept()
                }
                .tint(.green)
                .disabled(nickname.isEmpty)

                Button("Decline") {
                    decline()
                }
                .tint(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .task {
            if nickname.isEmpty, let localPart = account?.jid.localPart {
                nickname = localPart
            }
        }
    }

    private func accept() {
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty, let accountID = account?.id else { return }
        Task {
            do {
                try await environment.chatService.acceptInvite(invite, nickname: nick, accountID: accountID)
                openChat(invite.roomJIDString, accountID: accountID)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func decline() {
        guard let accountID = account?.id else { return }
        Task {
            do {
                try await environment.chatService.declineInvite(invite, accountID: accountID)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
