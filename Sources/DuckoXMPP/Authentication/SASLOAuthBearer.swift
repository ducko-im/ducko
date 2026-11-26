/// SASL OAUTHBEARER mechanism (RFC 7628).
///
/// The initial response carries the access token. A server that rejects it sends an error challenge, which the client
/// acknowledges with `\u{1}` before the server's `<failure>` (RFC 7628 §3.2.3).
struct SASLOAuthBearer {
    static let mechanismName = "OAUTHBEARER"

    private var sentEmptyToken = false
    /// The server's error challenge as received, kept for the failure that follows it.
    private var challenge: String?

    /// The opening of a sign-in: the mechanism to name, its state, and the initial response to send.
    struct Start {
        let mechanism: String
        let bearer: SASLOAuthBearer
        let initialResponse: [UInt8]
    }

    /// Starts a sign-in with `token`: only over TLS, and only where `offered` (uppercased names) lists OAUTHBEARER.
    static func start(token: String, offered: Set<String>, tlsActive: Bool) throws(SASLAuthError) -> Start {
        guard tlsActive else { throw .browserSignInNeedsTLS }
        let mechanism = try selectBearerMechanism(offered: offered)
        var bearer = SASLOAuthBearer()
        let payload = try bearer.initialResponse(token: token)
        return Start(mechanism: mechanism, bearer: bearer, initialResponse: payload)
    }

    /// The GS2 header and `auth` key-value of RFC 7628 §3.1, without an authorization identity. A token is sent only when
    /// it is made of visible ASCII, so no `\u{1}` or other framing byte can enter the message. RFC 6750's `b64token` is
    /// narrower, but providers issue tokens outside it, such as Prosody's `secret-token:…`.
    mutating func initialResponse(token: String) throws(SASLAuthError) -> [UInt8] {
        guard token.isEmpty || Self.isVisibleASCII(token) else { throw .unsendableBearerToken }
        sentEmptyToken = token.isEmpty
        return Array("n,,\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8)
    }

    /// Keeps the server's error challenge and answers it with `\u{1}`, which ends the exchange in a `<failure>`.
    mutating func handleChallenge(_ bytes: [UInt8]) -> Result<[UInt8], SASLAuthError> {
        guard let text = String(validating: bytes, as: UTF8.self) else { return .failure(.invalidBase64) }
        challenge = text
        return .success([0x01])
    }

    /// The `<response>` in the profile's `namespace` that answers the server's base64 `<challenge>`.
    mutating func respond(to stanza: XMLElement, namespace: String) -> Result<XMLElement, SASLAuthError> {
        guard let bytes = Base64.decode(stanza.textContent ?? "") else { return .failure(.invalidBase64) }
        return handleChallenge(bytes).map { reply in
            var element = XMLElement(name: "response", namespace: namespace)
            element.addText(Base64.encode(reply))
            return element
        }
    }

    /// A success after the empty probe, or after an error challenge this side acknowledged, is not a sign-in.
    func handleSuccess() -> SASLAuthError? {
        sentEmptyToken || challenge != nil ? .unexpectedReply : nil
    }

    func handleFailure(_ failure: XMLElement) -> SASLAuthError {
        guard case let .serverFailure(condition, text) = SASLAuthError.parse(failure: failure) else {
            return .parse(failure: failure)
        }
        return .bearerTokenRejected(challenge: challenge, condition: condition, text: text)
    }

    private static func isVisibleASCII(_ token: String) -> Bool {
        token.utf8.allSatisfy { (0x21 ... 0x7E).contains($0) }
    }
}
