import DuckoCore
import SwiftUI

/// Tab-based settings view for room administration.
struct RoomSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let roomJIDString: String
    let accountID: UUID

    @State private var selectedTab = Tab.general
    @State private var isDestroyConfirmPresented = false
    @State private var saveConfigRequested = false

    enum Tab: String, CaseIterable {
        case general = "General"
        case members = "Members"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .roomSettingsTabsPickerStyle()
            .padding()

            Divider()

            ZStack {
                RoomConfigView(roomJIDString: roomJIDString, accountID: accountID, saveRequested: $saveConfigRequested)
                    .opacity(selectedTab == .general ? 1 : 0)
                AffiliationListView(roomJIDString: roomJIDString, accountID: accountID)
                    .opacity(selectedTab == .members ? 1 : 0)
            }

            Divider()

            HStack {
                Button("Destroy Room…", role: .destructive) {
                    isDestroyConfirmPresented = true
                }
                .accessibilityIdentifier("room-settings-destroy")

                Spacer()

                // No `.accessibilityIdentifier` here: SwiftUI does not
                // reliably propagate the modifier to a `Button` carrying
                // `.keyboardShortcut(.defaultAction)` on macOS 26. UI tests
                // resolve this button via `AppAccessor.clickSheetButton(label:)`
                // which matches the SwiftUI button title against
                // `kAXDescriptionAttribute` (the attribute SwiftUI publishes
                // a `Button("Save") { … }` label through).
                Button("Save") {
                    saveConfigRequested = true
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 450)
        .confirmationDialog("Destroy Room?", isPresented: $isDestroyConfirmPresented) {
            Button("Destroy", role: .destructive) {
                Task {
                    try? await environment.chatService.destroyRoom(jidString: roomJIDString, accountID: accountID)
                    dismiss()
                }
            }
        } message: {
            Text("This will permanently destroy the room and remove all occupants. This action cannot be undone.")
        }
        .accessibilityIdentifier("room-settings-view")
    }
}

private extension View {
    @ViewBuilder
    func roomSettingsTabsPickerStyle() -> some View {
        if #available(macOS 27, *) {
            pickerStyle(.tabs)
        } else {
            pickerStyle(.segmented)
        }
    }
}

// MARK: - Affiliation List View

private struct AffiliationListView: View {
    @Environment(AppEnvironment.self) private var environment
    let roomJIDString: String
    let accountID: UUID

    @State private var items: [RoomAffiliationItem] = []
    @State private var selectedAffiliation: RoomAffiliation = .member
    @State private var newJID = ""
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 8) {
            Picker("Affiliation", selection: $selectedAffiliation) {
                Text("Members").tag(RoomAffiliation.member)
                Text("Admins").tag(RoomAffiliation.admin)
                Text("Owners").tag(RoomAffiliation.owner)
                Text("Outcasts").tag(RoomAffiliation.outcast)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .onChange(of: selectedAffiliation) {
                Task { await loadList() }
            }

            if isLoading {
                ProgressView()
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(item.jidString)
                                        .font(.body)
                                    Text(item.affiliation.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let nickname = item.nickname {
                                    Text(nickname)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let reason = item.reason {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button("Remove") {
                                Task {
                                    try? await environment.chatService.setAffiliation(
                                        jidString: item.jidString,
                                        inRoomJIDString: roomJIDString,
                                        to: .none,
                                        accountID: accountID
                                    )
                                    await loadList()
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.inset)

                HStack {
                    TextField("JID to add…", text: $newJID)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("affiliation-jid-field")

                    Button("Add") {
                        Task {
                            guard !newJID.isEmpty else { return }
                            try? await environment.chatService.setAffiliation(
                                jidString: newJID,
                                inRoomJIDString: roomJIDString,
                                to: selectedAffiliation,
                                accountID: accountID
                            )
                            newJID = ""
                            await loadList()
                        }
                    }
                    .disabled(newJID.isEmpty)
                    .accessibilityIdentifier("affiliation-add-button")
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .task {
            await loadList()
        }
        .accessibilityIdentifier("affiliation-list-view")
    }

    private func loadList() async {
        isLoading = true
        items = await (try? environment.chatService.getAffiliationList(
            affiliation: selectedAffiliation,
            inRoomJIDString: roomJIDString,
            accountID: accountID
        )) ?? []
        isLoading = false
    }
}
