import DuckoCore
import Foundation
import SwiftUI

struct ParticipantRow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openChat) private var openChat
    let participant: RoomParticipant
    let myParticipant: RoomParticipant?
    let roomJIDString: String
    /// The room's account, threaded down from the owning chat tab so room actions and the PM
    /// open route to the right account rather than re-deriving `accounts.first`.
    let accountID: UUID?
    @State private var isNickChangePresented = false
    @State private var newNickname = ""

    private var isSelf: Bool {
        guard let me = myParticipant else { return false }
        return participant.nickname == me.nickname
    }

    private var isOtherParticipant: Bool {
        guard let me = myParticipant else { return false }
        return participant.nickname != me.nickname
    }

    private var canKick: Bool {
        myParticipant?.role == .moderator && isOtherParticipant
    }

    private var canBan: Bool {
        let aff = myParticipant?.affiliation
        let isAdminOrOwner = aff == .admin || aff == .owner
        return isAdminOrOwner && isOtherParticipant && participant.jidString != nil
    }

    private var canGrantVoice: Bool {
        myParticipant?.role == .moderator && isOtherParticipant && participant.role == .visitor
    }

    private var canRevokeVoice: Bool {
        myParticipant?.role == .moderator && isOtherParticipant && participant.role == .participant
    }

    var body: some View {
        HStack(spacing: 8) {
            ParticipantAvatarView(nickname: participant.nickname)

            Text(participant.nickname)
                .singleLine()

            Spacer()

            if participant.role == .moderator {
                Text("Mod")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if isOtherParticipant {
                Button("Send Private Message") {
                    openChat("\(roomJIDString)/\(participant.nickname)", accountID: accountID)
                }
                .accessibilityIdentifier("send-pm-menu-item")
            }

            if canKick {
                Button("Kick") {
                    Task {
                        guard let accountID else { return }
                        try? await environment.chatService.kickOccupant(
                            nickname: participant.nickname,
                            fromRoomJIDString: roomJIDString,
                            reason: nil,
                            accountID: accountID
                        )
                    }
                }
            }

            if canBan, let jidString = participant.jidString {
                Button("Ban") {
                    Task {
                        guard let accountID else { return }
                        try? await environment.chatService.banUser(
                            jidString: jidString,
                            fromRoomJIDString: roomJIDString,
                            reason: nil,
                            accountID: accountID
                        )
                    }
                }
            }

            if canGrantVoice {
                Button("Grant Voice") {
                    Task {
                        guard let accountID else { return }
                        try? await environment.chatService.grantVoice(
                            nickname: participant.nickname,
                            inRoomJIDString: roomJIDString,
                            accountID: accountID
                        )
                    }
                }
            }

            if canRevokeVoice {
                Button("Revoke Voice") {
                    Task {
                        guard let accountID else { return }
                        try? await environment.chatService.revokeVoice(
                            nickname: participant.nickname,
                            inRoomJIDString: roomJIDString,
                            accountID: accountID
                        )
                    }
                }
            }

            if isSelf {
                Button("Change Nickname…") {
                    newNickname = participant.nickname
                    isNickChangePresented = true
                }
                .accessibilityIdentifier("change-nickname-menu-item")
            }
        }
        .alert("Change Nickname", isPresented: $isNickChangePresented) {
            TextField("Nickname", text: $newNickname)
                .accessibilityIdentifier("change-nickname-field")
            Button("Change") {
                Task {
                    guard let accountID, !newNickname.isEmpty else { return }
                    try? await environment.chatService.changeRoomNickname(
                        jidString: roomJIDString,
                        newNickname: newNickname,
                        accountID: accountID
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
