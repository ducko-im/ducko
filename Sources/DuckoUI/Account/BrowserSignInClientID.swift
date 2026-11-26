import DuckoCore
import SwiftUI

/// Why a form asks for a client ID that a server's administrator set up for Ducko.
enum BrowserSignInClientIDPrompt: Equatable {
    /// The provider does not let Ducko register itself.
    case required(issuer: String)
    /// The last sign-in did not complete, which a provider that refuses a retired client ID also causes.
    case optional

    /// The prompt a failed sign-in through the browser calls for, if any.
    init?(_ error: any Error) {
        switch error as? SSOError {
        case let .clientIDRequired(issuer):
            self = .required(issuer: issuer)
        case .cancelled, .timedOut, .authorizationDenied:
            self = .optional
        case .serverUnsupported, .registrationUnavailable, .browserUnavailable, .grantInvalid, .providerUnreachable,
             .malformedResponse, .storeFailed, nil:
            return nil
        }
    }
}

/// Asks for a client ID an administrator set up for the provider, naming the redirect addresses it must allow.
struct BrowserSignInClientIDField: View {
    let prompt: BrowserSignInClientIDPrompt
    @Binding var clientID: String

    private var message: String {
        switch prompt {
        case let .required(issuer):
            let addresses = SSORedirect.redirectURIs(forIssuer: issuer).joined(separator: " and ")
            return "Ask the administrator of \(issuer) for a client ID for Ducko that allows the redirect addresses \(addresses)."
        case .optional:
            return "If the sign-in provider does not accept Ducko, enter a client ID from the server's administrator."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            TextField(prompt == .optional ? "Client ID (optional)" : "Client ID", text: $clientID)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sso-client-id-field")
        }
    }
}

/// A form's sign-in through the browser: whether it is in progress, its failure, and the client ID it asks for.
@MainActor @Observable
final class BrowserSignInState {
    private(set) var isSigningIn = false
    private(set) var errorMessage: String?
    private(set) var clientIDPrompt: BrowserSignInClientIDPrompt?
    var clientID = ""

    /// Runs a sign-in with the entered client ID, or none while the field is empty. A sign-in that ends in a
    /// `CancellationError` lost the account to another connect, a disconnect or its removal, so it shows nothing.
    func signIn(_ action: (_ clientID: String?) async throws -> Void) async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            try await action(clientID.isEmpty ? nil : clientID)
            clientIDPrompt = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            guard let prompt = BrowserSignInClientIDPrompt(error) else { return }
            clientIDPrompt = prompt
            if prompt == .optional {
                clientID = ""
            }
        }
    }

    /// Clears the failure, the prompt and the client ID, so a client ID typed for one provider never reaches a later
    /// sign-in with another.
    func reset() {
        errorMessage = nil
        clientIDPrompt = nil
        clientID = ""
    }
}

/// The client ID field a form's last sign-in through the browser asked for, hidden while a sign-in is in progress.
struct BrowserSignInClientIDSlot: View {
    @Bindable var state: BrowserSignInState

    var body: some View {
        if let prompt = state.clientIDPrompt, !state.isSigningIn {
            BrowserSignInClientIDField(prompt: prompt, clientID: $state.clientID)
        }
    }
}

/// A button that starts a sign-in through the browser, with its progress beside it and its failure and client ID field
/// below it.
struct BrowserSignInControl: View {
    let label: String
    let identifier: String
    let state: BrowserSignInState
    let start: () -> Void

    var body: some View {
        HStack {
            Button(label, action: start)
                .disabled(state.isSigningIn)
                .accessibilityIdentifier(identifier)
            if state.isSigningIn {
                ProgressView()
                    .controlSize(.small)
            }
        }
        if let errorMessage = state.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .font(.callout)
        }
        BrowserSignInClientIDSlot(state: state)
    }
}

/// Offers sign-in through the browser after a password sign-in found that the server offers it. The form shows the
/// failure itself.
struct BrowserSignInOffer: View {
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("This server offers sign-in through a browser.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Sign In with Browser…", action: signIn)
                .accessibilityIdentifier("sso-sign-in-offer")
        }
    }
}
