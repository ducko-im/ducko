import DuckoCore
import SwiftUI

struct ChatHeaderView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(TranscriptScope.self) private var transcriptScope
    @Environment(\.openWindow) private var openWindow
    let conversation: Conversation
    var windowState: ChatWindowState?
    @State private var showDeviceFingerprints = false

    private var connectionState: AccountService.ConnectionState {
        conversation.accountID.flatMap { environment.accountService.connectionStates[$0] } ?? .disconnected
    }

    private var hasOutage: Bool {
        conversation.accountID.flatMap { environment.accountService.outageInfos[$0] } != nil
    }

    private var isOffline: Bool {
        switch connectionState {
        case .connected, .connecting: false
        case .disconnected, .error: true
        }
    }

    private var isGroupchat: Bool {
        conversation.type == .groupchat
    }

    /// A MUC private message — `room@conf/nick`, persisted as `type == .chat` with an
    /// occupant nickname. The occupant isn't a roster contact, so it gets no roster
    /// presence dot and no Get Info entry.
    private var isMUCPrivateMessage: Bool {
        !isGroupchat && conversation.occupantNickname != nil
    }

    private var participantCount: Int {
        guard let accountID = conversation.accountID else { return 0 }
        return environment.chatService.participantCount(forRoomJIDString: conversation.jid.description, accountID: accountID)
    }

    private var roomFlags: Set<RoomFlag> {
        guard let accountID = conversation.accountID else { return [] }
        return environment.chatService.roomFlags(forRoomJIDString: conversation.jid.description, accountID: accountID)
    }

    private var contact: Contact? {
        // Resolve within the conversation's own account; the unscoped lookup returns the
        // first match across accounts, which can be the wrong one when the same peer JID
        // is on two accounts. Imported conversations have no account — fall back.
        guard let accountID = conversation.accountID else {
            return environment.rosterService.contact(jidString: conversation.jid.description)
        }
        return environment.rosterService.contact(jidString: conversation.jid.description, accountID: accountID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if isGroupchat {
                    roomIdentity
                } else if isMUCPrivateMessage {
                    occupantIdentity
                } else {
                    peerIdentity
                }

                Spacer()

                trailingButtons
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if isOffline {
                disconnectedStrip
            }
        }
    }

    // MARK: - Identity

    private var roomIdentity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.displayTitle)
                .font(.headline)
                .singleLine()

            if participantCount > 0 {
                HStack(spacing: 4) {
                    Text("\(participantCount) participants")
                    if roomFlags.contains(.nonAnonymous) {
                        Text("·")
                        Text("non-anonymous")
                    }
                    if roomFlags.contains(.logged) {
                        Text("·")
                        Text("logged")
                    }
                    if hasOutage {
                        Text("·")
                        Text("service outage")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var occupantIdentity: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .font(.title)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayName ?? conversation.occupantNickname ?? conversation.jid.description)
                    .font(.headline)
                    .singleLine()
                Text("Private message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var peerIdentity: some View {
        // A chat with a non-roster peer has no subscription to reason from, so its
        // presence is genuinely unknown rather than offline. Reads are scoped to the
        // conversation's own account so a same-JID peer on two accounts shows the right one.
        let display = contact.map {
            ContactPresenceDisplay.resolve(for: $0, accountID: conversation.accountID, presenceService: environment.presenceService)
        } ?? .unknown
        let statusMessage: String? = if let accountID = conversation.accountID {
            environment.presenceService.statusMessage(for: conversation.jid, accountID: accountID)
        } else {
            environment.presenceService.statusMessage(for: conversation.jid)
        }

        return HStack(spacing: 8) {
            if let contact {
                AvatarView(contact: contact, size: 32)
            } else {
                AvatarView(imageData: nil, name: conversation.displayTitle, size: 32)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(contact?.displayName ?? conversation.displayName ?? conversation.jid.description)
                    .font(.headline)
                    .singleLine()

                HStack(spacing: 4) {
                    PresenceIndicator(display: display)

                    Text(joiningLines: statusMessage ?? display.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .singleLine()

                    if hasOutage {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("service outage")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Trailing Buttons

    @ViewBuilder
    private var trailingButtons: some View {
        if let contactInfoRef = conversation.contactInfoRef {
            Button {
                openWindow(id: "contact-info", value: contactInfoRef)
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Contact Info")
            .accessibilityIdentifier("contact-info-button")
        }

        Button {
            transcriptScope.request(ConversationRef(conversation: conversation))
            openWindow(id: "transcripts")
        } label: {
            Image(systemName: "clock")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("History")
        .accessibilityIdentifier("history-button")

        if let accountID = conversation.accountID {
            Menu {
                Button(conversation.encryptionEnabled ? "Disable Encryption" : "Enable Encryption") {
                    Task {
                        try? await environment.chatService.setEncryptionEnabled(
                            !conversation.encryptionEnabled,
                            for: conversation.id, accountID: accountID
                        )
                    }
                }
                Button("Device Fingerprints…") {
                    showDeviceFingerprints = true
                }
            } label: {
                Image(systemName: conversation.encryptionEnabled ? "lock.fill" : "lock.open")
                    .foregroundStyle(conversation.encryptionEnabled ? Color.green : .secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("encryption-menu")
            .sheet(isPresented: $showDeviceFingerprints) {
                DeviceFingerprintsSheet(
                    peerJID: conversation.jid.description,
                    accountID: accountID
                )
            }
        }

        if isGroupchat, let windowState {
            Button {
                windowState.showParticipantSidebar.toggle()
            } label: {
                Image(systemName: "person.2")
                    .foregroundStyle(windowState.showParticipantSidebar ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toggle-participant-sidebar")
        }
    }

    // MARK: - Disconnected Strip

    private var disconnectedStrip: some View {
        Text("You're offline — messages will send when you reconnect.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.12))
            .accessibilityIdentifier("disconnected-strip")
    }
}
