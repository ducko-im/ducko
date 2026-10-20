/// SASL namespace per RFC 6120 §6.
let saslNamespace = "urn:ietf:params:xml:ns:xmpp-sasl"

/// Channel binding type for `tls-server-end-point` (RFC 5929 §4.1).
let tlsServerEndPointCBType = "tls-server-end-point"

/// Result of a SASL exchange step.
enum SASLAuthResponse {
    case continueWith(XMLElement)
    case success
    case failure(SASLAuthError)
}

/// Errors that can occur during SASL authentication.
enum SASLAuthError: Error, Equatable {
    case noSupportedMechanism
    case invalidBase64
    case malformedChallenge(String)
    case invalidServerNonce
    case serverSignatureMismatch
    case serverFailure(condition: String, text: String?)
    case invalidState(String)
    case iterationCountTooLow(Int)
    case channelBindingDowngrade
    case unsupportedSignInStep

    /// A `.serverFailure` prefers the server's non-blank `text`, then a phrase for a known condition, then the raw
    /// condition name.
    var displayText: String {
        switch self {
        case .noSupportedMechanism: "The server offers no supported authentication mechanism"
        case .invalidBase64: "The server sent malformed authentication data"
        case let .malformedChallenge(reason): "The server sent a malformed challenge: \(reason)"
        case .invalidServerNonce: "The server sent an invalid nonce"
        case .serverSignatureMismatch: "The server could not prove it knows the password"
        case let .serverFailure(condition, text):
            if let text, !text.allSatisfy(\.isWhitespace) { text } else { Condition(rawValue: condition)?.displayText ?? condition }
        case let .invalidState(reason): "Unexpected authentication state: \(reason)"
        case let .iterationCountTooLow(count): "The server's password hashing is too weak (\(count) iterations)"
        case .channelBindingDowngrade: "The server's authentication options contradict each other, which can mean the connection is being tampered with"
        case .unsupportedSignInStep: "The server asked for an extra authentication step that is not supported"
        }
    }

    /// Parses a SASL or SASL2 `<failure>` element into a `.serverFailure` error.
    static func parse(failure: XMLElement) -> SASLAuthError {
        var condition = "unknown"
        var text: String?
        for case let .element(child) in failure.children {
            if child.name == "text" {
                text = child.textContent
            } else {
                condition = child.name
            }
        }
        return .serverFailure(condition: condition, text: text)
    }

    /// SASL failure conditions per RFC 6120 §6.5.
    enum Condition: String {
        case aborted
        case accountDisabled = "account-disabled"
        case credentialsExpired = "credentials-expired"
        case encryptionRequired = "encryption-required"
        case incorrectEncoding = "incorrect-encoding"
        case invalidAuthzid = "invalid-authzid"
        case invalidMechanism = "invalid-mechanism"
        case malformedRequest = "malformed-request"
        case mechanismTooWeak = "mechanism-too-weak"
        case notAuthorized = "not-authorized"
        case temporaryAuthFailure = "temporary-auth-failure"

        var displayText: String {
            switch self {
            case .aborted: "Aborted by the server"
            case .accountDisabled: "The account is disabled"
            case .credentialsExpired: "The password has expired"
            case .encryptionRequired: "The server requires an encrypted connection"
            case .incorrectEncoding, .malformedRequest: "The server rejected a malformed authentication request"
            case .invalidAuthzid: "The server rejected the authorization identity"
            case .invalidMechanism: "The server rejected the authentication mechanism"
            case .mechanismTooWeak: "The server requires a stronger authentication mechanism"
            case .notAuthorized: "Incorrect username or password"
            case .temporaryAuthFailure: "Temporary server failure, try again later"
            }
        }
    }
}

/// The channel-binding types the server lists in `<sasl-channel-binding>` directly under the stream features
/// (XEP-0440 §2). An absent element and an empty one both list none.
func parseChannelBindingTypes(_ features: XMLElement) -> Set<String> {
    Set(
        features.child(named: "sasl-channel-binding", namespace: XMPPNamespaces.saslChannelBinding)?
            .children(named: "channel-binding")
            .compactMap { $0.attribute("type") } ?? []
    )
}

/// Chooses how SCRAM binds to the TLS channel, per XEP-0440 §3, or throws when the offer looks downgraded.
///
/// "`-PLUS` offered" means any offered name ending in `-PLUS`, implemented or not, because a server offering any
/// `-PLUS` mechanism rejects `y,,` as a downgrade.
///
/// Three cases deliberately sign in unbound rather than abort, against rules 5 and 6 and RFC 5802 §6:
/// - Types listed without any `-PLUS`. Prosody does this with PLAIN-only auth backends, and it rejects `y,,`
///   whenever it lists types.
/// - Only types this client can't compute.
/// - SASL1 offering `-PLUS` without listing any type.
func chooseChannelBinding(
    bindingData: [UInt8]?,
    advertisedTypes: Set<String>,
    offeredMechanisms: Set<String>,
    isSASL2: Bool
) throws(SASLAuthError) -> ChannelBindingMode {
    guard let bindingData else { return .none }
    let plusOffered = offeredMechanisms.contains { $0.hasSuffix("-PLUS") }
    if isSASL2, plusOffered, advertisedTypes.isEmpty { throw .channelBindingDowngrade }
    let implementedPlusOffered = !offeredMechanisms.isDisjoint(with: [SCRAMMechanismName.sha256Plus, SCRAMMechanismName.sha1Plus])
    if advertisedTypes.contains(tlsServerEndPointCBType), implementedPlusOffered {
        return .bound(type: tlsServerEndPointCBType, data: bindingData)
    }
    if advertisedTypes.isEmpty, !plusOffered { return .clientSupportsButNotUsed }
    return .none
}

/// Builds SASL mechanism preference order for the chosen channel binding: only `-PLUS` mechanisms when bound, so a
/// stronger unbound mechanism never wins over binding, and none of them otherwise.
///
/// Shared between ``SASLAuthenticator`` (SASL1) and ``SASL2Authenticator`` (SASL2).
func buildSASLPreferenceOrder(channelBinding: ChannelBindingMode) -> [String] {
    switch channelBinding {
    case .bound:
        [SCRAMMechanismName.sha256Plus, SCRAMMechanismName.sha1Plus]
    case .none, .clientSupportsButNotUsed:
        [SCRAMMechanismName.sha256, SCRAMMechanismName.sha1, SASLPlain.mechanismName]
    }
}
