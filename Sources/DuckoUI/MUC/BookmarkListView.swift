import DuckoCore
import SwiftUI

struct BookmarkListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingAddSheet = false

    private var account: Account? {
        environment.accountService.accounts.first { $0.isEnabled }
    }

    var body: some View {
        Group {
            if environment.bookmarksService.bookmarks.isEmpty {
                ContentUnavailableView("No Bookmarks", systemImage: "bookmark", description: Text("Add a room bookmark to auto-join on connect."))
            } else {
                List(environment.bookmarksService.bookmarks) { bookmark in
                    BookmarkRow(bookmark: bookmark) {
                        removeBookmark(bookmark)
                    }
                    .containerAccessibilityIdentifier("bookmark-row-\(bookmark.jidString)")
                }
            }
        }
        .navigationTitle("Bookmarks")
        .toolbar {
            ToolbarItem {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Label("Add Bookmark", systemImage: "plus")
                }
                .accessibilityIdentifier("add-bookmark-button")
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AddBookmarkSheet()
        }
    }

    private func removeBookmark(_ bookmark: RoomBookmark) {
        guard let accountID = account?.id else { return }
        Task {
            try? await environment.bookmarksService.removeBookmark(
                jidString: bookmark.jidString, accountID: accountID
            )
        }
    }
}

private struct BookmarkRow: View {
    let bookmark: RoomBookmark
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.name ?? bookmark.jidString)
                    .fontWeight(.medium)
                if bookmark.name != nil {
                    Text(bookmark.jidString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let nick = bookmark.nickname {
                    Text("Nickname: \(nick)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if bookmark.autojoin {
                Text("autojoin")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("remove-bookmark-button")
        }
        .padding(.vertical, 2)
    }
}

private struct AddBookmarkSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var roomJID = ""
    @State private var name = ""
    @State private var nickname = ""
    @State private var autojoin = true
    @State private var password = ""
    @State private var errorMessage: String?

    private var account: Account? {
        environment.accountService.accounts.first { $0.isEnabled }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Bookmark")
                .font(.headline)

            TextField("Room JID (e.g. room@conference.example.com)", text: $roomJID)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
                .accessibilityIdentifier("bookmark-jid-field")

            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)

            TextField("Nickname", text: $nickname)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
                .accessibilityIdentifier("bookmark-nickname-field")

            SecureField("Password (optional)", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)

            Toggle("Auto-join on connect", isOn: $autojoin)
                .frame(maxWidth: 350)
                .accessibilityIdentifier("bookmark-autojoin-toggle")

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityIdentifier("add-bookmark-error")
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    addBookmark()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(roomJID.isEmpty || nickname.isEmpty)
                .accessibilityIdentifier("add-bookmark-confirm-button")
            }
        }
        .padding(20)
        .frame(minWidth: 400)
        .task {
            if nickname.isEmpty, let localPart = account?.jid.localPart {
                nickname = localPart
            }
        }
    }

    private func addBookmark() {
        guard let accountID = account?.id else { return }
        errorMessage = nil

        let bookmark = RoomBookmark(
            jidString: roomJID.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.isEmpty ? nil : name,
            autojoin: autojoin,
            nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.isEmpty ? nil : password
        )

        Task {
            do {
                try await environment.bookmarksService.addBookmark(bookmark, accountID: accountID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
