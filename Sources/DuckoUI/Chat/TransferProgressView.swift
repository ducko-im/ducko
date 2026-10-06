import DuckoCore
import SwiftUI

struct TransferProgressView: View {
    @Environment(AppEnvironment.self) private var environment
    /// The chat's account, so one account's transfers stay out of another's window.
    let accountID: UUID?

    var body: some View {
        // Only uploads are listed here. A file sent directly reports on its own row in the chat, and one being
        // received on a row standing in for the sender's message.
        let transfers = environment.fileTransferService.activeTransfers.filter {
            isUploading($0.state) && (accountID == nil || $0.accountID == accountID)
        }
        if !transfers.isEmpty {
            VStack(spacing: 4) {
                ForEach(transfers) { transfer in
                    TransferProgressRow(transfer: transfer)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("transfer-progress")
        }
    }

    private func isUploading(_ state: FileTransferService.TransferState) -> Bool {
        switch state {
        case .requestingSlot, .uploading:
            true
        case .completed, .failed, .negotiating, .connectingTransport, .transferring, .awaitingAcceptance,
             .completedTransfer, .received:
            false
        }
    }
}

// MARK: - TransferProgressRow

private struct TransferProgressRow: View {
    let transfer: FileTransferService.ActiveTransfer

    var body: some View {
        // On this account's side, where the uploaded file's message will be.
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.fileName)
                    .font(.callout)
                    .singleLine()

                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let progress = uploadProgress {
                ProgressView(value: progress)
                    .frame(width: 100)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Text(formattedFileSize)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: transfer.fileSize, countStyle: .file)
    }

    private var stateLabel: String {
        uploadProgress.map { "Uploading \(Int($0 * 100))%" } ?? "Requesting upload slot…"
    }

    /// `nil` while the upload's slot is still being requested.
    private var uploadProgress: Double? {
        if case let .uploading(progress) = transfer.state { progress } else { nil }
    }
}
