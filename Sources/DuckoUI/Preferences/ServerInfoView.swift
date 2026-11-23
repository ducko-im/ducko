import DuckoCore
import SwiftUI

struct ServerInfoView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let accountID: UUID

    @State private var serverInfo: ServerInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loadedContent
                    // Only the settled states carry this, so automation can tell
                    // a loaded sheet from one still waiting on the server.
                    .accessibilityIdentifier("server-info-content")
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 300)
        .task {
            await loadServerInfo()
        }
        .containerAccessibilityIdentifier("server-info-view")
        .onExitCommand { dismiss() }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let serverInfo, !serverInfo.contactAddresses.isEmpty {
            addressList(serverInfo)
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("No server contact information available.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addressList(_ info: ServerInfo) -> some View {
        List {
            let grouped = Dictionary(grouping: info.contactAddresses, by: \.type)
            ForEach(ContactAddressType.allCases, id: \.self) { type in
                if let addresses = grouped[type], !addresses.isEmpty {
                    Section(type.displayName) {
                        ForEach(addresses) { address in
                            addressRow(address)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func addressRow(_ address: ContactAddress) -> some View {
        if let url = URL(string: address.address) {
            Link(address.address, destination: url)
        } else {
            Text(address.address)
        }
    }

    private func loadServerInfo() async {
        isLoading = true
        do {
            serverInfo = try await environment.accountService.fetchServerInfo(accountID: accountID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
