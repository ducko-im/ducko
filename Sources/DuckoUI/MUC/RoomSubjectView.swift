import DuckoCore
import SwiftUI

struct RoomSubjectView: View {
    let windowState: ChatWindowState
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isTopicFieldFocused: Bool

    private var subject: String? {
        windowState.roomSubject
    }

    var body: some View {
        HStack {
            if isEditing {
                TextField("Room topic", text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTopicFieldFocused)
                    .onAppear { isTopicFieldFocused = true }
                    .accessibilityIdentifier("room-topic-field")

                Button("Save") {
                    let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await windowState.setRoomSubject(text) }
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("room-topic-save-button")

                Button("Cancel") {
                    isEditing = false
                }
                .controlSize(.small)
            } else {
                Text(joiningLines: subject ?? "No topic set")
                    .font(.callout)
                    .foregroundStyle(subject != nil ? .primary : .tertiary)
                    .singleLine()
                    .accessibilityIdentifier("room-topic-text")

                Spacer()

                Button {
                    editText = subject ?? ""
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("room-topic-edit-button")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .containerAccessibilityIdentifier("room-subject-view")
    }
}
