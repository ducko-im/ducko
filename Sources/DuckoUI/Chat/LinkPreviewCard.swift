import AppKit
import DuckoCore
import SwiftUI

struct LinkPreviewCard: View {
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let preview: LinkPreview

    var body: some View {
        Button {
            if let url = URL(string: preview.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            switch theme.current.linkPreviewStyle {
            case .full:
                fullPreview
            case .compact:
                compactPreview
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("link-preview")
    }

    @ViewBuilder
    private func previewImage(size: CGFloat, cornerRadius: CGFloat) -> some View {
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
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: cornerRadius))
        }
    }

    private var fullPreview: some View {
        HStack(spacing: 8) {
            previewImage(size: 48, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                if let title = preview.title {
                    Text(title)
                        .font(.callout)
                        .bold()
                        .lineLimit(1)
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
        .background(theme.current.backgroundColor.resolved(for: colorScheme), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.current.separatorColor.resolved(for: colorScheme), lineWidth: 0.5)
        )
    }

    private var compactPreview: some View {
        HStack(spacing: 6) {
            previewImage(size: 16, cornerRadius: 3)

            if let title = preview.title {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            if let siteName = preview.siteName {
                Text("— \(siteName)")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
