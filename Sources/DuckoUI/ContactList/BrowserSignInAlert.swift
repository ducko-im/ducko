import DuckoCore
import SwiftUI

extension View {
    /// Asks to sign an account in through the browser again once its provider no longer accepts the grant. Ducko never
    /// opens the browser by itself. Later hides the alert until the next connect finds the grant rejected.
    func browserSignInAlert() -> some View {
        modifier(BrowserSignInAlert())
    }
}

private struct BrowserSignInAlert: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @State private var signInError: String?

    private var pending: (id: UUID, jid: String)? {
        let service = environment.accountService
        return service.browserSignInNeeded.sorted { $0.uuidString < $1.uuidString }.lazy.compactMap { id in
            service.accounts.first { $0.id == id }.map { (id, $0.jid.description) }
        }.first
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Sign In Again",
                isPresented: Binding(get: { pending != nil }, set: { _ in }),
                presenting: pending
            ) { pending in
                Button("Later", role: .cancel) {
                    environment.accountService.dismissBrowserSignInAlert(for: pending.id)
                }
                .accessibilityIdentifier("browser-sign-in-later")
                Button("Sign In with Browser…") {
                    signIn(pending.id)
                }
                .accessibilityIdentifier("browser-sign-in-start")
            } message: { pending in
                Text("The sign-in provider no longer accepts the sign-in of \(pending.jid), so Ducko cannot connect it until it signs in through the browser again.")
            }
            .alert(
                "Could Not Sign In",
                isPresented: Binding(get: { signInError != nil }, set: { if !$0 { signInError = nil } })
            ) {
                Button("OK") { signInError = nil }
            } message: {
                if let signInError {
                    Text(signInError)
                }
            }
    }

    private func signIn(_ accountID: UUID) {
        // Hidden now, so the alert is not shown again while the sign-in is on its way.
        environment.accountService.dismissBrowserSignInAlert(for: accountID)
        Task {
            do {
                try await environment.accountService.signInWithBrowser(accountID: accountID)
            } catch SSOError.cancelled, is CancellationError {
                // The person closed the browser page, or another connect, a disconnect or the account's removal took
                // the account over meanwhile.
                return
            } catch {
                signInError = error.localizedDescription
                if case .clientIDRequired = error as? SSOError {
                    signInError? += ". Enter one with Sign In with Browser… in Settings > Accounts."
                }
            }
        }
    }
}
