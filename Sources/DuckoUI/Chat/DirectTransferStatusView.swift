import DuckoCore
import SwiftUI

/// What a file going directly between devices is doing. Its row says so itself, since no server holds the file to speak for it.
enum DirectTransferStatus: Equatable {
    /// Waiting for the contact, as the chat names them, to accept.
    case waiting(recipient: String)
    case sending(progress: Double)
    /// `nil` until the first bytes arrive.
    case receiving(progress: Double?)
    case failed(String)
    case sent

    /// A reason for failing may run over several lines. Every other state takes one line, however long the name in
    /// it, so a row keeps its height from one state to the next.
    var lineLimit: Int? {
        if case .failed = self { nil } else { 1 }
    }

    /// What the row of a file being received says.
    static func receiving(_ transfer: FileTransferService.ActiveTransfer) -> DirectTransferStatus {
        if case let .transferring(progress) = transfer.state { return .receiving(progress: progress) }
        return .receiving(progress: nil)
    }

    /// `nil` for anything but a file this account sent directly, and for one whose transfer was cut off by the app
    /// quitting, of which nothing is known. `recipientName` is the chat's name.
    static func resolve(
        for message: ChatMessage, transfer: FileTransferService.ActiveTransfer?, recipientName: String
    ) -> DirectTransferStatus? {
        guard message.isOutgoing, message.attachments.contains(where: { $0.localFileURL != nil }) else { return nil }
        // The stored outcome comes first, so a row reads the same while the app runs as after a relaunch.
        if let errorText = message.errorText { return .failed(errorText) }
        if message.isDelivered { return .sent }
        switch transfer?.state {
        case .negotiating, .awaitingAcceptance: return .waiting(recipient: recipientName)
        case .connectingTransport: return .sending(progress: 0)
        case let .transferring(progress): return .sending(progress: progress)
        case let .failed(reason): return .failed(reason)
        case .completedTransfer: return .sent
        case .requestingSlot, .uploading, .completed, .received, nil: return nil
        }
    }
}

struct DirectTransferStatusView: View {
    let status: DirectTransferStatus?

    /// Fits the tallest state that takes one line, the one with a progress bar, so the row keeps its height as the
    /// transfer moves from one state to the next.
    private static let lineHeight: CGFloat = 20

    var body: some View {
        if let status {
            Group {
                switch status {
                case let .waiting(recipient):
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Waiting for \(recipient) to accept…")
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
            .lineLimit(status.lineLimit)
            .frame(minHeight: Self.lineHeight)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("direct-transfer-status")
        }
    }
}
