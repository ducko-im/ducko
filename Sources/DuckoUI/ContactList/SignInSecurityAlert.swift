import DuckoCore
import SwiftUI

extension View {
    /// Warns that an account was not signed in because the server offered only a sign-in that sends the password,
    /// after the account had signed in without sending it. Keeping the refusal hides the warning until the next refused
    /// attempt. Resetting asks for confirmation first.
    func signInSecurityAlert() -> some View {
        modifier(SignInSecurityAlert())
    }
}

private struct SignInSecurityAlert: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @State private var pendingReset: UUID?
    @State private var resetError: String?

    private var warning: (id: UUID, value: AccountService.SignInSecurityWarning)? {
        environment.accountService.signInSecurityWarnings.first.map { ($0.key, $0.value) }
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Sign-In Refused",
                isPresented: Binding(
                    get: { warning != nil && pendingReset == nil },
                    set: { _ in }
                ),
                presenting: warning
            ) { warning in
                Button("Keep Refusing", role: .cancel) {
                    environment.accountService.dismissSignInSecurityWarning(for: warning.id)
                }
                .accessibilityIdentifier("sign-in-security-keep-refusing")
                Button("Reset Sign-In Security…") {
                    pendingReset = warning.id
                }
                .accessibilityIdentifier("sign-in-security-reset")
            } message: { warning in
                Text("""
                \(warning.value.accountJID) has signed in before without sending its password. The server now offers \
                only a sign-in that sends the password, so Ducko did not sign in. Someone may be intercepting the \
                connection, or the server's setup changed.
                """)
            }
            .confirmationDialog(
                "Reset sign-in security?",
                isPresented: Binding(
                    get: { pendingReset != nil },
                    set: { if !$0 { pendingReset = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingReset
            ) { accountID in
                Button("Reset and Sign In", role: .destructive) {
                    resetAndSignIn(accountID)
                }
                .accessibilityIdentifier("sign-in-security-reset-confirm")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("""
                Ducko will send the password to this server, which anyone intercepting the connection could read. Reset \
                only if you know the server's setup changed. Ducko refuses again after the next sign-in that does not \
                send the password.
                """)
            }
            .modifier(ResetFailureAlert(message: $resetError))
    }

    private func resetAndSignIn(_ accountID: UUID) {
        pendingReset = nil
        // Hidden now, so the refusal is not shown again while the reset is still on its way.
        environment.accountService.dismissSignInSecurityWarning(for: accountID)
        Task {
            do {
                try await environment.accountService.resetSignInSecurity(for: accountID)
            } catch {
                resetError = error.localizedDescription
                return
            }
            try? await environment.accountService.connect(accountID: accountID)
        }
    }
}

private struct ResetFailureAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .alert(
                "Sign-In Security Reset Failed",
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
