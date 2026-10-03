import DuckoCore
import SwiftUI

/// What a file going directly between devices is doing. Its row says so itself, since no server holds the file to speak for it.
enum DirectTransferStatus: Equatable {
    case waiting
    case sending(progress: Double)
    /// `nil` until the first bytes arrive.
    case receiving(progress: Double?)
    case failed(String)
    case sent

    /// `nil` for anything but a file this account sent directly or is receiving right now, and for a sent one whose
    /// transfer was cut off by the app quitting, of which nothing is known.
    static func resolve(for message: ChatMessage, transfer: FileTransferService.ActiveTransfer?) -> DirectTransferStatus? {
        guard message.isOutgoing else {
            // Only the row standing in for a file still on its way has a transfer under its id.
            guard let transfer, transfer.isReceiving else { return nil }
            if case let .transferring(progress) = transfer.state { return .receiving(progress: progress) }
            return .receiving(progress: nil)
        }
        guard message.attachments.contains(where: { $0.localFileURL != nil }) else { return nil }
        // The stored outcome comes first, so a row reads the same while the app runs as after a relaunch.
        if let errorText = message.errorText { return .failed(errorText) }
        if message.isDelivered { return .sent }
        switch transfer?.state {
        case .negotiating, .awaitingAcceptance: return .waiting
        case .connectingTransport: return .sending(progress: 0)
        case let .transferring(progress): return .sending(progress: progress)
        case let .failed(reason): return .failed(reason)
        case .completedTransfer: return .sent
        case .requestingSlot, .uploading, .completed, .received, nil: return nil
        }
    }
}

struct DirectTransferStatusView: View {
    @Environment(AppEnvironment.self) private var environment
    let message: ChatMessage

    private var status: DirectTransferStatus? {
        // A file's row and its transfer share one id.
        .resolve(for: message, transfer: environment.fileTransferService.activeTransfers.first { $0.id == message.id })
    }

    /// The contact as the rest of the chat names them: by the chat's own name, else their roster name, else their JID.
    private var recipientName: String {
        let conversation = environment.chatService.openConversations.first { $0.id == message.conversationID }
        let contact = conversation?.accountID.flatMap {
            environment.rosterService.contact(jidString: message.fromJID, accountID: $0)
        }
        return conversation?.displayName ?? contact?.displayName ?? message.fromJID
    }

    var body: some View {
        if let status {
            Group {
                switch status {
                case .waiting:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Waiting for \(recipientName) to accept…")
                    }
                case let .sending(progress):
                    HStack(spacing: 6) {
                        Text("Sending directly…")
                        ProgressView(value: progress)
                            .frame(width: 80)
                    }
                case let .receiving(progress):
                    HStack(spacing: 6) {
                        if let progress {
                            ProgressView(value: progress)
                                .frame(width: 80)
                        } else {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text("Receiving…")
                    }
                case let .failed(reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                case .sent:
                    Text("Sent directly")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("direct-transfer-status")
        }
    }
}
