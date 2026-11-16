/// SASL namespace per RFC 6120 §6.
let saslNamespace = "urn:ietf:params:xml:ns:xmpp-sasl"

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
    /// The SCRAM server-first-message lacks the nonce, salt, or iteration count.
    case malformedChallenge
    case invalidServerNonce
    /// The server ends SCRAM without the signature that proves it knows the password.
    case serverProofMissing
    case serverSignatureMismatch
    case serverFailure(condition: String, text: String?)
    /// The server ends SCRAM with an RFC 5802 `e=` error value, which only the debug log shows.
    case scramServerError(String)
    /// A reply arrives before sign-in starts, or a SCRAM step arrives out of order.
    case unexpectedReply
    /// A reply element no sign-in step defines, whose name only the debug log shows.
    case unknownReply(element: String)
    case accountAddressMissing
    case unrequestedResume
    case iterationCountTooLow(Int)
    /// `-PLUS` is offered over SASL2 without any channel-binding type listed (XEP-0440 rule 4).
    case channelBindingTypesMissing
    /// Channel-binding types are listed without any `-PLUS` mechanism (XEP-0440 rule 5).
    case channelBindingMechanismMissing
    /// `-PLUS` is offered, but with no listed type this side can compute, or only `-PLUS` mechanisms it does not
    /// implement (XEP-0440 rule 6).
    case channelBindingUnavailable
    /// The server's XEP-0474 hash of the offer does not match the offer as it arrived.
    case mechanismListTampered
    /// The server's XEP-0515 TLS version does not match the one negotiated.
    case tlsVersionTampered
    case unsupportedSignInStep
    /// The server's `<task-data>` for the SCRAM upgrade has no salt, an empty one, or no numeric iteration count
    /// (XEP-0480 §3).
    case malformedUpgradeTask
    /// The server offers only PLAIN, which sends the password itself, to an account that does not allow it.
    case plainRefused

    /// A `.serverFailure` prefers the server's non-blank `text`, then a phrase for a known condition, then a general
    /// refusal.
    var displayText: String {
        switch self {
        case .noSupportedMechanism: "The server offers no supported authentication mechanism"
        case .invalidBase64: "The server sent malformed authentication data"
        case .malformedChallenge: "The server sent an incomplete sign-in challenge"
        case .invalidServerNonce: "The server sent an invalid nonce"
        case .serverProofMissing: "The server left out its proof that it knows the password"
        case .serverSignatureMismatch: "The server could not prove it knows the password"
        case let .serverFailure(condition, text):
            if let text, !text.allSatisfy(\.isWhitespace) { text } else { Condition(rawValue: condition)?.displayText ?? "The server refused the sign-in" }
        case .scramServerError: "The server refused the sign-in"
        case .unexpectedReply: "The server sent a sign-in reply out of order"
        case .unknownReply: "The server sent an unknown sign-in reply"
        case .accountAddressMissing: "The server's sign-in confirmation has no valid account address"
        case .unrequestedResume: "The server resumed a session that was not requested"
        case let .iterationCountTooLow(count): "The server's password hashing is too weak (\(count) iterations)"
        case .channelBindingTypesMissing:
            "The server's sign-in options are missing required security information, which can mean the connection is being tampered with"
        case .channelBindingMechanismMissing:
            "The server advertises sign-in protection but offers no sign-in method that uses it, which can mean the connection is being tampered with"
        case .channelBindingUnavailable: "The server offers only sign-in protection that this client cannot use on this connection"
        case .mechanismListTampered: "The server's sign-in options were changed on the way, which can mean the connection is being tampered with"
        case .tlsVersionTampered: "The connection's encryption version was changed on the way, which can mean the connection is being tampered with"
        case .unsupportedSignInStep: "The server asked for an extra authentication step that is not supported"
        case .malformedUpgradeTask: "The server sent an incomplete request to upgrade how it stores the password"
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
private let scramPlusPreferenceOrder = SCRAMHash.allCases.map(\.plusMechanismName)

private let implementedPlusMechanisms = Set(scramPlusPreferenceOrder)

/// Chooses how SCRAM binds to the TLS channel, per XEP-0440 §3, or throws where those rules say to abort.
///
/// "`-PLUS` offered" means any offered name ending in `-PLUS`, implemented or not, because a server offering any
/// `-PLUS` mechanism rejects `y,,` as a downgrade. The rules, in order:
/// - Without bindings, which means without TLS, the client cannot bind and signs in with `n,,` (rule 2).
/// - `-PLUS` without listed types aborts over SASL2 (rule 4). Over SASL1, rule 4 allows trying `tls-server-end-point`,
///   so an implemented `-PLUS` binds with it. A server that cannot check that binding refuses the sign-in. An offer
///   whose only `-PLUS` mechanisms are unimplemented aborts, as under rule 6.
/// - Listed types without any `-PLUS` abort (rule 5).
/// - Neither types nor `-PLUS` sign in with `y,,` (rule 3).
/// - An implemented `-PLUS` binds with the most preferred type that is both listed and computed.
/// - Otherwise no listed type can be computed here, or only unimplemented `-PLUS` mechanisms are offered, and the
///   sign-in aborts (rule 6).
///
/// This client does not take XEP-0474 §7's relaxation of rule 6, which signs in unbound once the server's hash confirms
/// the offer. The hash shows the offer arrived unchanged, not that binding was impossible: an interceptor holding a
/// trusted certificate picks the TLS version, so it can leave the client only types it cannot compute and relay the
/// unbound sign-in.
func chooseChannelBinding(
    bindings: [ChannelBindingType: [UInt8]],
    advertisedTypes: Set<String>,
    offeredMechanisms: Set<String>,
    isSASL2: Bool
) throws(SASLAuthError) -> ChannelBindingMode {
    guard !bindings.isEmpty else { return .none }
    let plusOffered = offeredMechanisms.contains { $0.hasSuffix("-PLUS") }
    let implementedPlusOffered = !offeredMechanisms.isDisjoint(with: implementedPlusMechanisms)
    if plusOffered, advertisedTypes.isEmpty {
        if isSASL2 { throw .channelBindingTypesMissing }
        guard implementedPlusOffered, let data = bindings[.tlsServerEndPoint] else { throw .channelBindingUnavailable }
        return .bound(type: .tlsServerEndPoint, data: data)
    }
    if !plusOffered {
        guard advertisedTypes.isEmpty else { throw .channelBindingMechanismMissing }
        return .clientSupportsButNotUsed
    }
    if implementedPlusOffered {
        for type in ChannelBindingType.allCases.sorted(by: { $0.preferenceRank < $1.preferenceRank })
            where advertisedTypes.contains(type.rawValue) {
            if let data = bindings[type] { return .bound(type: type, data: data) }
        }
    }
    throw .channelBindingUnavailable
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
        SCRAMHash.allCases.map(\.mechanismName)
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
