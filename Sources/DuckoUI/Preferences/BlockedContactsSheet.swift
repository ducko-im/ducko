import DuckoCore
import SwiftUI

struct BlockedContactsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let accountID: UUID

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var newAddress = ""
    @State private var changeError: String?

    private var entries: [BlockListEntry] {
        environment.rosterService.blockList(for: accountID)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loadedContent
                    // Only the settled states carry this, so automation can tell
                    // a loaded sheet from one still waiting on the server.
                    .accessibilityIdentifier("blocked-contacts-content")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Address to block", text: $newAddress)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("block-address-field")

                    Button("Block") {
                        block()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedAddress.isEmpty)
                    .accessibilityIdentifier("block-address-button")
                }

                if let changeError {
                    Text(changeError)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .accessibilityIdentifier("blocked-contacts-error")
                }

                HStack {
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding()
        }
        .frame(width: 400, height: 360)
        .task {
            await loadBlockList()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blocked-contacts-view")
    }

    private var trimmedAddress: String {
        newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let loadError {
            Text(loadError)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            Text("No blocked contacts.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(entries) { entry in
                HStack {
                    Text(entry.jidString)
                        .singleLine()
                        .accessibilityIdentifier("blocked-contact-\(entry.jidString)")

                    Spacer()

                    Button("Unblock") {
                        unblock(entry)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("unblock-button-\(entry.jidString)")
                }
            }
            .listStyle(.inset)
        }
    }

    private func loadBlockList() async {
        isLoading = true
        do {
            try await environment.rosterService.loadBlockList(accountID: accountID)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func block() {
        let address = trimmedAddress
        changeError = nil
        Task {
            do {
                try await environment.rosterService.blockContact(jidString: address, accountID: accountID)
                newAddress = ""
            } catch {
                changeError = error.localizedDescription
            }
        }
    }

    private func unblock(_ entry: BlockListEntry) {
        changeError = nil
        Task {
            do {
                try await environment.rosterService.unblockContact(jidString: entry.jidString, accountID: accountID)
            } catch {
                changeError = error.localizedDescription
            }
        }
    }
}
