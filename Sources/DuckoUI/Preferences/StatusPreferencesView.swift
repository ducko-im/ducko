import DuckoCore
import SwiftUI

/// Manages the saved custom statuses that appear in the Contacts "me" header dropdown — Adium's Status
/// preferences pane. Edits the shared `StatusBarPreferences`, so the header reflects changes live.
struct StatusPreferencesView: View {
    @Environment(StatusBarPreferences.self) private var preferences
    @State private var selection: SavedStatus.ID?
    @State private var isShowingAddSheet = false

    private struct SavedStatus: Identifiable {
        let status: PresenceService.PresenceStatus
        let message: String
        var id: String {
            "\(status.rawValue)|\(message)"
        }
    }

    private var savedStatuses: [SavedStatus] {
        PresenceService.PresenceStatus.selectableCases.flatMap { status in
            preferences.savedMessages(for: status).map { SavedStatus(status: status, message: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(savedStatuses, selection: $selection) { saved in
                HStack(spacing: 8) {
                    PresenceIndicator(status: saved.status)
                    Text(joiningLines: saved.message)
                        .singleLine()
                    Spacer()
                    Text(saved.status.displayName)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .tag(saved.id)
            }
            .listStyle(.bordered)
            .takesKeyboardOnClick()
            .overlay {
                if savedStatuses.isEmpty {
                    Text("No saved statuses. Add one to reuse it from the status menu.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }

            HStack(spacing: 0) {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Saved Status")

                Button {
                    deleteSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .accessibilityLabel("Remove Saved Status")

                Spacer()
            }
            .padding(.top, 6)
        }
        .padding()
        .frame(height: 420)
        .sheet(isPresented: $isShowingAddSheet) {
            SavedStatusAddSheet()
        }
        .accessibilityIdentifier("status-preferences")
    }

    private func deleteSelected() {
        guard let selection,
              let saved = savedStatuses.first(where: { $0.id == selection }) else { return }
        preferences.removeMessage(saved.message, for: saved.status)
        self.selection = nil
    }
}

private struct SavedStatusAddSheet: View {
    @Environment(StatusBarPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var status: PresenceService.PresenceStatus = .available
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Status", selection: $status) {
                    ForEach(PresenceService.PresenceStatus.selectableCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                TextField("Message", text: $message)
                    .accessibilityIdentifier("saved-status-message-field")
                    .onSubmit { add() }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    add()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 360)
    }

    private func add() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        preferences.saveMessage(trimmed, for: status)
        dismiss()
    }
}
