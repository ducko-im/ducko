import DuckoCore
import SwiftUI

extension View {
    /// Warns that an account was not signed in because the server offered only a sign-in that sends the password, which
    /// the account does not allow. Not allowing it hides the warning until the next refused attempt. Allowing it asks
    /// for confirmation first.
    func signInSecurityAlert() -> some View {
        modifier(SignInSecurityAlert())
    }
}

private struct SignInSecurityAlert: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @State private var pendingAllow: UUID?
    @State private var allowError: String?

    private var warning: (id: UUID, value: AccountService.SignInSecurityWarning)? {
        environment.accountService.signInSecurityWarnings.first.map { ($0.key, $0.value) }
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Sign-In Refused",
                isPresented: Binding(
                    get: { warning != nil && pendingAllow == nil },
                    set: { _ in }
                ),
                presenting: warning
            ) { warning in
                Button("Don't Allow", role: .cancel) {
                    environment.accountService.dismissSignInSecurityWarning(for: warning.id)
                }
                .accessibilityIdentifier("sign-in-security-dont-allow")
                Button("Allow Sending Password…") {
                    pendingAllow = warning.id
                }
                .accessibilityIdentifier("sign-in-security-allow")
            } message: { warning in
                Text("""
                The server for \(warning.value.accountJID) offers only a sign-in that sends the password, so Ducko did \
                not sign in. Allow it only if you trust this server and your connection to it.
                """)
            }
            .confirmationDialog(
                "Allow sending the password?",
                isPresented: Binding(
                    get: { pendingAllow != nil },
                    set: { if !$0 { pendingAllow = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingAllow
            ) { accountID in
                Button("Allow and Sign In", role: .destructive) {
                    allowAndSignIn(accountID)
                }
                .accessibilityIdentifier("sign-in-security-allow-confirm")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(plainAllowanceWarning)
            }
            .modifier(AllowFailureAlert(message: $allowError))
    }

    private func allowAndSignIn(_ accountID: UUID) {
        pendingAllow = nil
        // Hidden now, so the refusal is not shown again while the change is still on its way.
        environment.accountService.dismissSignInSecurityWarning(for: accountID)
        Task {
            do {
                try await environment.accountService.setAllowsPLAIN(true, for: accountID)
            } catch {
                allowError = error.localizedDescription
                return
            }
            try? await environment.accountService.connect(accountID: accountID)
        }
    }
}

private struct AllowFailureAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .alert(
                "Could Not Allow Sending the Password",
                isPresented: Binding(
                    get: { message != nil },
                    set: { if !$0 { message = nil } }
                )
            ) {
                Button("OK") { message = nil }
            } message: {
                if let message {
                    Text(message)
                }
            }
    }
}
