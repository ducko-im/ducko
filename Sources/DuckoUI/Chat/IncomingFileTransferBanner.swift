import DuckoCore
import SwiftUI

struct IncomingFileTransferBanner: View {
    @Environment(AppEnvironment.self) private var environment
    /// Each offer's last Accept or Decline error, by offer id. Held here rather than in the row: an offer leaves the
    /// list while it is acted on and returns when that fails, and its row returns as a new view.
    @State private var errors: [String: String] = [:]

    var body: some View {
        let offers = environment.fileTransferService.viewIncomingOffers
        if !offers.isEmpty {
            VStack(spacing: 4) {
                ForEach(offers) { offer in
                    IncomingFileTransferRow(
                        offer: offer,
                        errorMessage: Binding(get: { errors[offer.offerID] }, set: { errors[offer.offerID] = $0 })
                    )
                }
            }
            .padding(.vertical, 4)
            .background(Palette.accent.opacity(0.1))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("file-transfer-banner")
        }
    }
}

// MARK: - IncomingFileTransferRow

private struct IncomingFileTransferRow: View {
    @Environment(AppEnvironment.self) private var environment
    let offer: FileTransferService.IncomingFileOffer
    @Binding var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("File offer: \(offer.fileName)")
                        .font(.callout)
                        .lineLimit(1)

                    Text("\(formattedFileSize) from \(offer.fromJIDString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Accept") {
                    accept()
                }
                .tint(.green)
                .accessibilityIdentifier("accept-file-transfer-button")

                Button("Decline") {
                    decline()
                }
                .tint(.red)
                .accessibilityIdentifier("decline-file-transfer-button")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: offer.fileSize, countStyle: .file)
    }

    private func accept() {
        perform { accountID in
            try await environment.fileTransferService.acceptIncomingTransfer(offer.offerID, accountID: accountID)
        }
    }

    private func decline() {
        perform { accountID in
            try await environment.fileTransferService.declineIncomingTransfer(offer.offerID, accountID: accountID)
        }
    }

    /// The banner lists every account's offers, so each row acts on the account its own offer arrived on.
    private func perform(_ action: @escaping (UUID) async throws -> Void) {
        Task {
            do {
                try await action(offer.accountID)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
