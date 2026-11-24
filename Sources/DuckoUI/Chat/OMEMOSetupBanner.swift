import DuckoCore
import SwiftUI

/// Visible in a chat with encryption on while this Mac's encryption setup for the chat's account is incomplete or
/// refused. Try Again sets it up again. Dismiss hides the banner in this chat until the next attempt fails.
struct OMEMOSetupBanner: View {
    @Bindable var windowState: ChatWindowState

    var body: some View {
        if let problem = windowState.omemoSetupProblem, let message = Self.message(for: problem) {
            DismissibleBanner(message: message, alignment: .center, dismissalLabel: "Dismiss notice") {
                windowState.dismissOMEMOSetupProblem()
            } accessory: {
                retryButton
            }
            .containerAccessibilityIdentifier("omemo-setup-banner")
        }
    }

    private var retryButton: some View {
        Button {
            Task { await windowState.retryOMEMOSetup() }
        } label: {
            if windowState.isRetryingOMEMOSetup {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Trying…")
                }
            } else {
                Text("Try Again")
            }
        }
        .disabled(!windowState.canRetryOMEMOSetup)
        .accessibilityIdentifier("omemo-setup-retry-button")
    }

    static func message(for problem: OMEMOSetupState) -> String? {
        switch problem {
        case .incomplete:
            "This Mac's encryption setup is incomplete. You may miss encrypted replies here."
        case .refused:
            "The server refused to store this Mac's encryption keys, so you may miss encrypted replies here. Its operator can fix this."
        case .pending, .complete:
            nil
        }
    }
}
