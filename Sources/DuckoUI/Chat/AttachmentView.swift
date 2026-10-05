import AppKit
import DuckoCore
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentView: View {
    @Environment(RemoteImageConsent.self) private var remoteImageConsent
    let attachment: Attachment
    let isOutgoing: Bool
    /// Whether a received remote image is fetched without the viewer asking for it.
    let loadsIncomingImageOnSight: Bool
    @State private var showQuickLook = false
    @State private var showSheet = false
    @State private var isHovering = false

    /// Your own image is a link you chose, so fetching it tells nobody anything new.
    private var showsRemoteImage: Bool {
        isOutgoing || loadsIncomingImageOnSight || remoteImageConsent.isRequested(attachment.id)
    }

    private static let maxImageSize: CGFloat = 240

    var body: some View {
        Group {
            if attachment.isImage {
                imageAttachment
            } else {
                fileAttachment
            }
        }
        .background {
            if let localFileURL {
                QuickLookPreview(fileURL: localFileURL, isPresented: $showQuickLook)
            }
        }
        .onHover { isHovering = $0 }
        .sheet(isPresented: $showSheet) {
            ImagePreviewSheet(attachment: attachment)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachment-view")
    }

    /// A saved file opens the system Quick Look panel. A remote image that is not shown yet is fetched by the first
    /// tap, and one that is shown opens the in-app sheet.
    private func openPreview() {
        if localFileURL != nil {
            showQuickLook = true
        } else if attachment.isImage, attachment.remoteURL != nil, !showsRemoteImage {
            remoteImageConsent.request(attachment.id)
        } else if attachment.isImage {
            showSheet = true
        }
    }

    private var imageAttachment: some View {
        Group {
            if let localFileURL {
                localImage(localFileURL)
                    // Aligned to the message's own side: the cap is a maximum, so a smaller image would otherwise
                    // float in the middle of the capped frame.
                    .frame(maxWidth: Self.maxImageSize, maxHeight: Self.maxImageSize, alignment: isOutgoing ? .trailing : .leading)
            } else {
                // One frame whatever a remote image's state, so its row keeps its height while the image waits for
                // a click, loads, or fails. The image has no size to read until it has loaded.
                Color.clear
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .frame(maxWidth: Self.maxImageSize)
                    .overlay { remoteImage }
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .onTapGesture { openPreview() }
        .overlay(alignment: .bottomTrailing) {
            if let localFileURL, isHovering {
                revealButton(localFileURL)
                    .padding(6)
            }
        }
    }

    @ViewBuilder
    private var remoteImage: some View {
        if let imageURL = attachment.remoteURL {
            // Rendering a peer's URL on sight would fetch it, telling the sender the recipient's address and the
            // moment they read the message, so unless told otherwise the viewer asks first.
            if showsRemoteImage {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        imagePlaceholder(systemName: "photo.badge.exclamationmark")
                    case .empty:
                        imagePlaceholder(systemName: "photo")
                            .overlay { ProgressView() }
                    @unknown default:
                        imagePlaceholder(systemName: "photo")
                    }
                }
            } else {
                imagePlaceholder(systemName: "photo.badge.arrow.down")
                    .accessibilityIdentifier("attachment-load-image")
            }
        } else {
            imagePlaceholder(systemName: "photo")
        }
    }

    /// A saved file is read from disk: `AsyncImage` fetches through URLSession, which does not load `file://` URLs, so
    /// it would show its failure placeholder for every file this app itself saved.
    @ViewBuilder
    private func localImage(_ url: URL) -> some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                // Bounded by the image's own size as well as the cap, so a small one is shown as it is rather than
                // blown up to fill the frame. A remote image has no size to read until it loads, so it only gets the cap.
                .frame(maxWidth: min(image.size.width, Self.maxImageSize), maxHeight: min(image.size.height, Self.maxImageSize))
        } else {
            // The saved file was moved, deleted, or cannot be decoded.
            imagePlaceholder(systemName: "photo.badge.exclamationmark")
                .frame(minWidth: 120, minHeight: 80)
                .fixedSize()
        }
    }

    /// Drawn as a bubble of its own: an image-only message has none around it, and a bare icon would float on the chat
    /// background. The file's name is all that says what the image is while it is not shown. Fills the frame it is
    /// given.
    private func imagePlaceholder(systemName: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.largeTitle)

            Text(attachment.displayFileName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Palette.bubbleText(isOutgoing: isOutgoing).opacity(0.6))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bubble(isOutgoing: isOutgoing), in: .rect(cornerRadius: 8))
    }

    private var fileAttachment: some View {
        HStack(spacing: 8) {
            Button {
                openPreview()
            } label: {
                fileSummary
            }
            .buttonStyle(.plain)
            .disabled(localFileURL == nil)
            .accessibilityIdentifier("attachment-preview-button")

            if let localFileURL {
                // Shown by presence rather than by opacity: an invisible button still takes clicks and still answers
                // to VoiceOver.
                if isHovering {
                    revealButton(localFileURL)
                }
            } else if let remoteURL = attachment.remoteURL {
                Button {
                    NSWorkspace.shared.open(remoteURL)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("attachment-open-button")
            }
        }
        .padding(8)
        .background(
            isOutgoing
                ? Palette.outgoingBubble.opacity(0.3)
                : Color(.textBackgroundColor),
            in: .rect(cornerRadius: 8)
        )
    }

    private var fileSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon)
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayFileName)
                    .font(.callout)
                    .lineLimit(1)

                if let oobDescription = attachment.oobDescription, !oobDescription.isEmpty {
                    Text(oobDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let size = attachment.formattedFileSize {
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .contentShape(.rect)
    }

    private var localFileURL: URL? {
        attachment.localFileURL
    }

    private func revealButton(_ url: URL) -> some View {
        Button {
            revealInFinder([url])
        } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Reveal in Finder")
        .accessibilityIdentifier("attachment-reveal-button")
    }

    private var fileIcon: String {
        guard let mimeType = attachment.mimeType,
              let utType = UTType(mimeType: mimeType) else {
            return "doc"
        }

        if utType.conforms(to: .pdf) { return "doc.richtext" }
        if utType.conforms(to: .audio) { return "music.note" }
        if utType.conforms(to: .movie) { return "film" }
        if utType.conforms(to: .archive) { return "doc.zipper" }
        if utType.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}
