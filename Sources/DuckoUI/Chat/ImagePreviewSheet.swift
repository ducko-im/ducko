import AppKit
import DuckoCore
import SwiftUI

struct ImagePreviewSheet: View {
    @Environment(AppEnvironment.self) private var environment
    let attachment: Attachment
    /// An encrypted image, decrypted in memory, which the sheet shows and saves in place of fetching the attachment.
    var decryptedImage: DecryptedImage?
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(attachment.displayFileName)
                    .font(.headline)

                Spacer()

                Button("Save to Downloads") {
                    saveToDownloads()
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            imageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.05))
        }
        .frame(minWidth: 400, minHeight: 300)
        .accessibilityIdentifier("image-preview")
        // The service already composes the whole sentence, so the alert carries it as it is rather than adding a second
        // label on top of it. Presented straight from the optional, so dismissing clears the text with it.
        .alert(saveError ?? "", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let decryptedImage {
            Image(nsImage: decryptedImage.image)
                .resizable()
                .scaledToFit()
                .padding()
                .accessibilityLabel(attachment.displayFileName)
        } else if let imageURL = attachment.remoteURL {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .padding()
                case .failure:
                    Label("Failed to load image", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                case .empty:
                    ProgressView()
                @unknown default:
                    EmptyView()
                }
            }
        } else {
            Label("No image URL", systemImage: "photo")
                .foregroundStyle(.secondary)
        }
    }

    private func saveToDownloads() {
        let service = environment.fileTransferService
        let fileName = attachment.displayFileName
        let decryptedBytes = decryptedImage?.bytes
        let imageURL = attachment.remoteURL
        Task {
            do {
                try await Self.save(decryptedBytes: decryptedBytes, orFetching: imageURL, named: fileName, with: service)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// Saves the image to the downloads folder: the bytes an encrypted image was decrypted to as they are, else the
    /// remote image fetched again.
    static func save(decryptedBytes: [UInt8]?, orFetching imageURL: URL?, named fileName: String, with service: FileTransferService) async throws {
        if let decryptedBytes {
            _ = try await service.saveDecryptedFile(decryptedBytes, named: fileName)
        } else if let imageURL {
            _ = try await service.saveRemoteImage(from: imageURL, named: fileName)
        }
    }
}
