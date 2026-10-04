import SwiftUI

/// Shown while the reader is away from the newest message, to go back to it.
struct JumpToNewestButton: View {
    let scroller: TranscriptScroller

    var body: some View {
        Button {
            scroller.scrollToNewest()
        } label: {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                // A plain button takes clicks only where its label draws, which is the glyph alone.
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: .circle)
        .overlay {
            Circle().strokeBorder(.separator)
        }
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .help("Jump to Newest Message")
        .accessibilityLabel("Jump to Newest Message")
        .accessibilityIdentifier("jump-to-newest")
    }
}
