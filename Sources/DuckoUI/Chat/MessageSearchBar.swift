import SwiftUI

/// The find bar above a message list.
struct MessageSearchBar: View {
    @Binding var text: String
    let matchTotal: Int
    /// The current match's number, counted from one, or nil while none is current.
    let currentMatchNumber: Int?
    var focusesOnAppear = true
    var showsProgress = false
    let onSubmit: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDone: () -> Void
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Search messages", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .onAppear {
                    if focusesOnAppear { isTextFieldFocused = true }
                }
                .onSubmit(onSubmit)

            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }

            if matchTotal > 0 {
                Text(currentMatchNumber.map { "\($0)/\(matchTotal)" } ?? "\(matchTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button("Previous Match", systemImage: "chevron.up", action: onPrevious)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)

                Button("Next Match", systemImage: "chevron.down", action: onNext)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }

            Button("Done", action: onDone)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
        .accessibilityIdentifier("message-search-bar")
    }
}
