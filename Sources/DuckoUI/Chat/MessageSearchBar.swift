import SwiftUI

/// The find bar above a message list.
struct MessageSearchBar: View {
    @Binding var text: String
    let matchTotal: Int
    /// The current match's number, counted from one, or nil while none is current.
    let currentMatchNumber: Int?
    var focusesOnAppear = true
    /// Changes whenever the field is to take the keyboard.
    var focusRequest = 0
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
                    // Asked one turn later. On appearing, the field is not in the window yet, and asked then, it does
                    // not get the keyboard.
                    if focusesOnAppear { Task { isTextFieldFocused = true } }
                }
                .onChange(of: focusRequest) { isTextFieldFocused = true }
                .onSubmit(onSubmit)
                .onExitCommand(perform: onDone)
                .accessibilityIdentifier("message-search-field")

            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("message-search-progress")
            }

            if matchTotal > 0 {
                Text(currentMatchNumber.map { "\($0)/\(matchTotal)" } ?? "\(matchTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("message-search-count")

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
        .containerAccessibilityIdentifier("message-search-bar")
    }
}
