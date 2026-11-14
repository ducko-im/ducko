/// SASL PLAIN mechanism (RFC 4616).
///
/// Single-step: `\0authcid\0password` base64-encoded in `<auth>`.
struct SASLPlain {
    static let mechanismName = "PLAIN"

    mutating func start(authcid: String, password: String) -> XMLElement {
        // PLAIN payload: [authzid] \0 authcid \0 password
        let payload: [UInt8] = [0] + Array(authcid.utf8) + [0] + Array(password.utf8)

        var auth = XMLElement(name: "auth", namespace: saslNamespace, attributes: ["mechanism": Self.mechanismName])
        auth.addText(Base64.encode(payload))
        return auth
    }

    mutating func handleChallenge(_: XMLElement) -> SASLAuthResponse {
        .failure(.unsupportedSignInStep)
    }

    mutating func handleSuccess(_: XMLElement) -> SASLAuthResponse {
        .success
    }
}
