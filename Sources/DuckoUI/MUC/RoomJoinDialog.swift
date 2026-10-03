import DuckoCore
import SwiftUI

struct RoomJoinDialog: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    var onJoin: (String, UUID?) -> Void
    @State private var roomJID = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var discoveredRooms: [DiscoveredRoom] = []
    @State private var searchedChannels: [SearchedChannel] = []
    @State private var searchText = ""
    @State private var mucService: String?
    @State private var isBrowsing = false
    @State private var isSearching = false
    @State private var hasMoreResults = false
    @State private var lastSearchQuery = ""
    @State private var lastCursor: String?

    private var account: Account? {
        environment.accountService.accounts.first
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Join Room")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Room address or JID (e.g. room@conference.example.com)", text: $roomJID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("room-jid-field")

                if !roomJID.contains("@"), let mucService {
                    Text("Service: \(mucService)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 350)

            TextField("Nickname", text: $nickname)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
                .accessibilityIdentifier("room-nickname-field")

            SecureField("Password (optional)", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                TextField("Search channels…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
                    .onSubmit { searchChannels() }
                    .accessibilityIdentifier("channel-search-field")

                Button("Search") {
                    searchChannels()
                }
                .disabled(searchText.isEmpty || isSearching)
                .accessibilityIdentifier("channel-search-button")

                Button("Browse Rooms") {
                    browseRooms()
                }
                .disabled(isBrowsing)
                .accessibilityIdentifier("browse-rooms-button")

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Join") {
                    joinRoom()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(roomJID.isEmpty || nickname.isEmpty)
                .accessibilityIdentifier("join-room-button")
            }

            if !searchedChannels.isEmpty {
                channelSearchResults
            } else if !discoveredRooms.isEmpty {
                discoveredRoomsList
            }
        }
        .padding(20)
        .frame(minWidth: 400)
        .task {
            if nickname.isEmpty, let localPart = account?.jid.localPart {
                nickname = localPart
            }
            guard let accountID = account?.id else { return }
            mucService = await environment.chatService.discoverMUCService(accountID: accountID)
        }
    }

    // MARK: - Results Views

    private var channelSearchResults: some View {
        VStack(spacing: 4) {
            Divider()

            Text("Search Results")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List(searchedChannels) { channel in
                HStack {
                    VStack(alignment: .leading) {
                        Text(channel.name ?? channel.jidString)
                            .fontWeight(.medium)
                        if channel.name != nil {
                            Text(channel.jidString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if let userCount = channel.userCount {
                        Text("\(userCount) users")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let isOpen = channel.isOpen {
                        Text(isOpen ? "Open" : "Closed")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(isOpen ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Button("Join") {
                        roomJID = channel.jidString
                        joinRoom()
                    }
                }
            }
            .listStyle(.plain)
            .frame(height: 150)

            if hasMoreResults {
                Button("Load More") {
                    loadMoreResults()
                }
                .disabled(isSearching)
            }
        }
    }

    private var discoveredRoomsList: some View {
        VStack(spacing: 4) {
            Divider()

            Text("Available Rooms")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List(discoveredRooms) { room in
                HStack {
                    VStack(alignment: .leading) {
                        Text(room.name ?? room.jidString)
                            .fontWeight(.medium)
                        if room.name != nil {
                            Text(room.jidString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button("Join") {
                        roomJID = room.jidString
                        joinRoom()
                    }
                }
            }
            .listStyle(.plain)
            .frame(height: 150)
        }
    }

    // MARK: - Actions

    private func joinRoom() {
        let trimmedInput = roomJID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty, !trimmedNick.isEmpty else { return }
        errorMessage = nil

        guard let accountID = account?.id else { return }

        let pw = password.isEmpty ? nil : password
        Task {
            let resolvedJID: String
            if trimmedInput.contains("@") {
                resolvedJID = trimmedInput
            } else {
                let normalized = trimmedInput.lowercased().replacingOccurrences(of: " ", with: "-")
                guard !normalized.contains("/") else {
                    errorMessage = "Room name cannot contain / characters"
                    return
                }
                // ensureMUCService is a service-discovery IQ; its IQ result
                // can't be confused for a room join echo, so awaiting before
                // waiter registration is safe.
                await ensureMUCService(accountID: accountID)
                guard let service = mucService else {
                    errorMessage = "No MUC service found on server"
                    return
                }
                resolvedJID = "\(normalized)@\(service)"
            }

            guard JIDValidation.isValidUserOrRoomJID(resolvedJID) else {
                errorMessage = "Invalid room JID: \(resolvedJID)"
                return
            }

            do {
                try await environment.chatService.joinRoomAwaitingEcho(
                    jidString: resolvedJID, nickname: trimmedNick, password: pw, accountID: accountID
                )
            } catch {
                errorMessage = error.localizedDescription
                return
            }

            onJoin(resolvedJID, accountID)
            dismiss()
        }
    }

    private func ensureMUCService(accountID: UUID) async {
        if mucService == nil {
            mucService = await environment.chatService.discoverMUCService(accountID: accountID)
        }
    }

    private func browseRooms() {
        guard let accountID = account?.id else { return }
        isBrowsing = true
        searchedChannels = []
        Task {
            await ensureMUCService(accountID: accountID)
            guard let service = mucService else {
                errorMessage = "No MUC service found on server"
                isBrowsing = false
                return
            }
            do {
                discoveredRooms = try await environment.chatService.discoverRooms(on: service, accountID: accountID)
            } catch {
                errorMessage = error.localizedDescription
            }
            isBrowsing = false
        }
    }

    private func searchChannels() {
        guard let accountID = account?.id, !searchText.isEmpty else { return }
        isSearching = true
        discoveredRooms = []
        lastSearchQuery = searchText
        lastCursor = nil
        Task {
            do {
                let result = try await environment.chatService.searchChannels(keyword: searchText, accountID: accountID)
                searchedChannels = result.channels
                hasMoreResults = result.hasMore
                lastCursor = result.lastCursor
            } catch {
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func loadMoreResults() {
        guard let accountID = account?.id, let cursor = lastCursor else { return }
        isSearching = true
        Task {
            do {
                let result = try await environment.chatService.searchChannels(keyword: lastSearchQuery, accountID: accountID, after: cursor)
                searchedChannels.append(contentsOf: result.channels)
                hasMoreResults = result.hasMore
                lastCursor = result.lastCursor
            } catch {
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }
}
