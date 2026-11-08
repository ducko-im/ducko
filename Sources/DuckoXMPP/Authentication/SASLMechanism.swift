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
    /// The server's XEP-0474 hash of the offer does not match the offer as it arrived.
    case mechanismListTampered
    /// The server's XEP-0515 TLS version does not match the one negotiated.
    case tlsVersionTampered
    case unsupportedSignInStep
    /// The server offers only PLAIN, which sends the password itself, to an account that does not allow it.
    case plainRefused

    /// A `.serverFailure` prefers the server's non-blank `text`, then a phrase for a known condition, then a general
    /// refusal.
    var displayText: String {
        switch self {
        case .noSupportedMechanism: "The server offers no supported authentication mechanism"
        case .invalidBase64: "The server sent malformed authentication data"
        case let .malformedChallenge(reason): "The server sent a malformed challenge: \(reason)"
        case .invalidServerNonce: "The server sent an invalid nonce"
        case .serverSignatureMismatch: "The server could not prove it knows the password"
        case let .serverFailure(condition, text):
            if let text, !text.allSatisfy(\.isWhitespace) { text } else { Condition(rawValue: condition)?.displayText ?? "The server refused the sign-in" }
        case let .invalidState(reason): "Unexpected authentication state: \(reason)"
        case let .iterationCountTooLow(count): "The server's password hashing is too weak (\(count) iterations)"
        case .channelBindingDowngrade: "The server's authentication options contradict each other, which can mean the connection is being tampered with"
        case .mechanismListTampered: "The server's sign-in options were changed on the way, which can mean the connection is being tampered with"
        case .tlsVersionTampered: "The connection's encryption version was changed on the way, which can mean the connection is being tampered with"
        case .unsupportedSignInStep: "The server asked for an extra authentication step that is not supported"
        case .plainRefused: "The server offers only a sign-in that sends the password, which this account does not allow"
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
    Set(advertisedChannelBindingTypeList(features) ?? [])
}

/// The `-PLUS` mechanisms this client can bind with, strongest first.
private let scramPlusPreferenceOrder = [
    SCRAMMechanismName.sha3_512Plus, SCRAMMechanismName.sha512Plus, SCRAMMechanismName.sha256Plus, SCRAMMechanismName.sha1Plus
]

private let implementedPlusMechanisms = Set(scramPlusPreferenceOrder)

/// Chooses how SCRAM binds to the TLS channel, per XEP-0440 §3, or throws when the offer looks downgraded.
///
/// "`-PLUS` offered" means any offered name ending in `-PLUS`, implemented or not, because a server offering any
/// `-PLUS` mechanism rejects `y,,` as a downgrade.
///
/// Three cases sign in unbound rather than abort. The server-first message's XEP-0474 hash then checks that choice: a
/// match proves the offer genuine (XEP-0474 §7), and a mismatch fails the sign-in before the proof goes out. Without a
/// hash the choice goes against rules 5 and 6 and RFC 5802 §6.
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
    let implementedPlusOffered = !offeredMechanisms.isDisjoint(with: implementedPlusMechanisms)
    if advertisedTypes.contains(tlsServerEndPointCBType), implementedPlusOffered {
        return .bound(type: tlsServerEndPointCBType, data: bindingData)
    }
    if advertisedTypes.isEmpty, !plusOffered { return .clientSupportsButNotUsed }
    return .none
}

/// Builds SASL mechanism preference order for the chosen channel binding: only `-PLUS` mechanisms when bound, so a
/// stronger unbound mechanism never wins over binding, and none of them otherwise. PLAIN is in it only when allowed.
///
/// Shared between ``SASLAuthenticator`` (SASL1) and ``SASL2Authenticator`` (SASL2).
func buildSASLPreferenceOrder(channelBinding: ChannelBindingMode, allowsPLAIN: Bool) -> [String] {
    switch channelBinding {
    case .bound:
        scramPlusPreferenceOrder
    case .none, .clientSupportsButNotUsed:
        [SCRAMMechanismName.sha3_512, SCRAMMechanismName.sha512, SCRAMMechanismName.sha256, SCRAMMechanismName.sha1]
            + (allowsPLAIN ? [SASLPlain.mechanismName] : [])
    }
}

/// The first offered mechanism in preference order. Unless PLAIN is allowed, an offer whose only usable mechanism is
/// PLAIN is refused, so the password never goes out.
func selectSASLMechanism(
    offered: Set<String>,
    channelBinding: ChannelBindingMode,
    allowsPLAIN: Bool
) throws(SASLAuthError) -> String {
    let preferenceOrder = buildSASLPreferenceOrder(channelBinding: channelBinding, allowsPLAIN: allowsPLAIN)
    if let selected = preferenceOrder.first(where: { offered.contains($0) }) { return selected }
    if !allowsPLAIN, offered.contains(SASLPlain.mechanismName) { throw .plainRefused }
    throw .noSupportedMechanism
}
