import AppKit
import DuckoCore
import SwiftUI

struct PendingAttachmentBar: View {
    @Bindable var windowState: ChatWindowState

    var body: some View {
        if !windowState.pendingAttachments.isEmpty {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(windowState.pendingAttachments) { attachment in
                            PendingAttachmentChip(attachment: attachment) {
                                windowState.removeAttachment(id: attachment.id)
                            }
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.top, 8)
                }
                // Never, not hidden: with scroll bars set to always show, a hidden one still appears and doubles the
                // bar's height.
                .scrollIndicators(.never)
                // On the scroll view alone: an identifier on the whole bar would replace the pop-up's own.
                .accessibilityIdentifier("pending-attachments")

                if windowState.offersDirectTransfer || windowState.sendsFilesUnencryptedInEncryptedChat {
                    VStack(alignment: .trailing, spacing: 1) {
                        if windowState.offersDirectTransfer {
                            sendMethodPicker
                        }
                        // Said once beneath the menu rather than in each of its items, which keeps them short.
                        if windowState.sendsFilesUnencryptedInEncryptedChat {
                            Text("Not end-to-end encrypted")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Files are not end-to-end encrypted")
                                .accessibilityIdentifier("attachment-encryption-note")
                        }
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                }
            }
        }
    }

    /// Both ways are always listed, so a direct transfer that is not possible right now shows greyed out instead of
    /// going missing.
    private var sendMethodPicker: some View {
        Picker("Send", selection: $windowState.sendsAttachmentsDirectly) {
            Text("Upload").tag(false)
            Text("Send Directly")
                .tag(true)
                .selectionDisabled(!windowState.canSendDirectly)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("attachment-send-method")
        .task(id: windowState.contactOnlineResources) {
            await windowState.refreshDirectTransferSupport()
        }
    }
}

// MARK: - PendingAttachmentChip

/// One queued file on a single line, so the bar stays as low as the message field it sits above.
private struct PendingAttachmentChip: View {
    private static let thumbnailSize: CGFloat = 24

    let attachment: DraftAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            thumbnail
                .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)

            Text(attachment.fileName)
                .font(.callout)
                .singleLine()
                .truncationMode(.middle)
                .frame(maxWidth: 180)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.fileName)")
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if attachment.isImage, let nsImage = NSImage(contentsOf: attachment.url) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                .clipShape(.rect(cornerRadius: 5))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
