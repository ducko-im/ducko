/// Why a sign-in failed: what the user can do about it, readable text, and the server's condition when it sent one.
public struct AuthenticationFailure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The server rejected the username or password.
        case credentialsRejected
        /// The server failed for a reason that can clear by itself.
        case temporary
        case other
    }

    public let kind: Kind
    public let message: String
    /// The server's raw failure condition: a SASL `<failure>` condition such as `not-authorized`, or a SCRAM `e=` value
    /// such as `invalid-proof`.
    public let serverCondition: String?

    public init(kind: Kind, message: String, serverCondition: String? = nil) {
        self.kind = kind
        self.message = message
        self.serverCondition = serverCondition
    }

    /// Classified from the condition alone, never from the server's text.
    init(_ error: SASLAuthError) {
        let condition: String?
        let saslCondition: SASLAuthError.Condition?
        if case let .serverFailure(failureCondition, _) = error {
            condition = failureCondition
            saslCondition = SASLAuthError.Condition(rawValue: failureCondition)
        } else if case let .scramServerError(value) = error {
            condition = value
            saslCondition = SASLAuthError.SCRAMErrorValue(serverValue: value).condition
        } else {
            condition = nil
            saslCondition = nil
        }
        let kind: Kind = switch saslCondition {
        case .notAuthorized: .credentialsRejected
        case .temporaryAuthFailure: .temporary
        case .aborted, .accountDisabled, .credentialsExpired, .encryptionRequired, .incorrectEncoding, .invalidAuthzid,
             .invalidMechanism, .malformedRequest, .mechanismTooWeak, nil: .other
        }
        self.init(kind: kind, message: error.displayText, serverCondition: condition)
    }
}
