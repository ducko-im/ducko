/// Why a sign-in failed: what the user can do about it, readable text, and the server's condition when it sent one.
public struct AuthenticationFailure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The server rejected the username or password, or the access token.
        case credentialsRejected
        /// The server failed for a reason that can clear by itself.
        case temporary
        /// A password sign-in found that the server offers only sign-in through a browser.
        case browserSignInOnly
        /// A browser sign-in signed in to another account than the one entered.
        case accountMismatch
        case other
    }

    public let kind: Kind
    public let message: String
    /// The server's raw failure condition: a SASL `<failure>` condition such as `not-authorized`, or a SCRAM `e=` value
    /// such as `invalid-proof`.
    public let serverCondition: String?
    /// The error challenge a server sent before refusing an OAUTHBEARER sign-in (RFC 7628 §3.2.2).
    public let bearerChallenge: String?

    public init(kind: Kind, message: String, serverCondition: String? = nil, bearerChallenge: String? = nil) {
        self.kind = kind
        self.message = message
        self.serverCondition = serverCondition
        self.bearerChallenge = bearerChallenge
    }

    /// Classified from the condition alone, never from the server's text.
    init(_ error: SASLAuthError) {
        let condition: String?
        let saslCondition: SASLAuthError.Condition?
        var bearerChallenge: String?
        switch error {
        case let .serverFailure(failureCondition, _):
            condition = failureCondition
            saslCondition = SASLAuthError.Condition(rawValue: failureCondition)
        case let .bearerTokenRejected(challenge, failureCondition, _):
            condition = failureCondition
            saslCondition = SASLAuthError.Condition(rawValue: failureCondition)
            bearerChallenge = challenge
        case let .scramServerError(value):
            condition = value
            saslCondition = SASLAuthError.SCRAMErrorValue(serverValue: value).condition
        case .browserSignInOnly:
            self.init(kind: .browserSignInOnly, message: error.displayText)
            return
        case .accountMismatch:
            self.init(kind: .accountMismatch, message: error.displayText)
            return
        case .noSupportedMechanism, .invalidBase64, .malformedChallenge, .invalidServerNonce, .serverProofMissing,
             .serverSignatureMismatch, .unexpectedReply, .unknownReply, .accountAddressMissing, .unrequestedResume,
             .iterationCountTooLow, .iterationCountTooHigh, .channelBindingTypesMissing, .channelBindingMechanismMissing,
             .channelBindingUnavailable, .mechanismListTampered, .tlsVersionTampered, .unsupportedSignInStep,
             .malformedUpgradeTask, .plainRefused, .browserSignInUnavailable, .browserSignInNeedsTLS, .unsendableBearerToken:
            condition = nil
            saslCondition = nil
        }
        let kind: Kind = switch saslCondition {
        case .notAuthorized: .credentialsRejected
        case .temporaryAuthFailure: .temporary
        case .aborted, .accountDisabled, .credentialsExpired, .encryptionRequired, .incorrectEncoding, .invalidAuthzid,
             .invalidMechanism, .malformedRequest, .mechanismTooWeak, nil: .other
        }
        self.init(kind: kind, message: error.displayText, serverCondition: condition, bearerChallenge: bearerChallenge)
    }
}

/// Names only the kind and condition, so logging a failure never writes the server's text or its bearer challenge.
extension AuthenticationFailure: CustomStringConvertible {
    public var description: String {
        "AuthenticationFailure(kind: \(kind), serverCondition: \(serverCondition ?? "none"))"
    }
}
