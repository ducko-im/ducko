import Foundation

/// Why a sign-in through the browser, or the refresh of its grant, did not succeed.
public enum SSOError: Error, Equatable, LocalizedError {
    /// The server does not point to an authorization server Ducko can use.
    case serverUnsupported
    /// The authorization server does not let Ducko register, so an administrator must set up a client for it.
    case clientIDRequired(issuer: String)
    case registrationUnavailable
    /// The user or the provider declined the sign-in.
    case authorizationDenied
    case cancelled
    /// The sign-in page was left open longer than Ducko waits for it.
    case timedOut
    /// No browser can be opened here.
    case browserUnavailable
    /// The provider no longer accepts the account's grant, so the user must sign in with the browser again.
    case grantInvalid
    /// The provider could not be reached, which can clear by itself.
    case providerUnreachable
    case malformedResponse
    case storeFailed

    public var errorDescription: String? {
        switch self {
        case .serverUnsupported: "The server does not offer sign-in through a browser"
        case .clientIDRequired: "The sign-in provider needs a client ID from the server's administrator"
        case .registrationUnavailable: "The sign-in provider does not let Ducko register itself"
        case .authorizationDenied: "The sign-in provider did not grant access"
        case .cancelled: "The sign-in was cancelled"
        case .timedOut: "The sign-in was not completed in time"
        case .browserUnavailable: "Sign-in through a browser is not available here"
        case .grantInvalid: "The browser sign-in is no longer valid, so the account needs to sign in with the browser again"
        case .providerUnreachable: "Could not reach the sign-in provider"
        case .malformedResponse: "The sign-in provider sent a response Ducko cannot use"
        case .storeFailed: "Could not store the browser sign-in"
        }
    }
}
