import DuckoCore
import SwiftUI

struct SubscriptionRequestBanner: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var errorMessage: String?

    private var account: Account? {
        environment.accountService.accounts.first
    }

    var body: some View {
        let requests = environment.presenceService.pendingSubscriptionRequests
        if !requests.isEmpty {
            VStack(spacing: 4) {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .padding(.horizontal, 12)
                }

                ForEach(requests, id: \.description) { jid in
                    HStack {
                        Text("\(jid.description) wants to subscribe")
                            .font(.callout)
                            .singleLine()

                        Spacer()

                        Button("Accept") {
                            approve(jidString: jid.description)
                        }
                        .tint(.green)

                        Button("Decline") {
                            deny(jidString: jid.description)
                        }
                        .tint(.red)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 4)
            .background(.yellow.opacity(0.1))
        }
    }

    private func approve(jidString: String) {
        guard let accountID = account?.id else { return }
        Task {
            do {
                try await environment.rosterService.approveSubscription(
                    jidString: jidString,
                    accountID: accountID
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deny(jidString: String) {
        guard let accountID = account?.id else { return }
        Task {
            do {
                try await environment.rosterService.denySubscription(
                    jidString: jidString,
                    accountID: accountID
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
