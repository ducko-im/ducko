import SwiftUI

struct ReplyQuoteView: View {
    let senderName: String
    let bodyPreview: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Palette.accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(senderName)
                    .font(.caption2)
                    .bold()

                Text(bodyPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }
}
