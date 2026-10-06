import AppKit
import DuckoCore
import SwiftUI

struct LinkPreviewCard: View {
    let preview: LinkPreview

    var body: some View {
        Button {
            if let url = URL(string: preview.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            card
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("link-preview")
    }

    @ViewBuilder
    private var previewImage: some View {
        if let imageURLString = preview.imageURL, let imageURL = URL(string: imageURLString) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty, .failure:
                    Color.clear
                @unknown default:
                    Color.clear
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(.rect(cornerRadius: 6))
        }
    }

    private var card: some View {
        HStack(spacing: 8) {
            previewImage

            VStack(alignment: .leading, spacing: 2) {
                if let title = preview.title {
                    Text(joiningLines: title)
                        .font(.callout)
                        .bold()
                        .singleLine()
                }

                if let description = preview.descriptionText {
                    Text(description)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }

                if let siteName = preview.siteName {
                    Text(siteName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        // The card paints its own background, so its text must not inherit the bubble's color.
        .foregroundStyle(Color.primary)
        .padding(8)
        .background(Color(.textBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Palette.separator, lineWidth: 0.5)
        )
    }
}
