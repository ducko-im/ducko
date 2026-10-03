import DuckoCore
import SwiftUI

/// Editable room configuration form. Embedded inside `RoomSettingsView`'s General tab.
struct RoomConfigView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let roomJIDString: String
    let accountID: UUID
    @Binding var saveRequested: Bool

    @State private var fields: [RoomConfigField] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading room configuration…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Failed to load configuration",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                configForm
            }
        }
        .task {
            await loadConfig()
        }
        .onChange(of: saveRequested) {
            if saveRequested {
                Task {
                    await saveConfig()
                }
            }
        }
        .accessibilityIdentifier("room-config-view")
    }

    private var configForm: some View {
        Form {
            DataFormFieldsView(fields: $fields)
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func loadConfig() async {
        do {
            fields = try await environment.chatService.getRoomConfig(jidString: roomJIDString, accountID: accountID)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func saveConfig() async {
        do {
            try await environment.chatService.submitRoomConfig(jidString: roomJIDString, fields: fields, accountID: accountID)
            saveRequested = false
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            saveRequested = false
        }
    }
}
