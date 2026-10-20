import CryptoKit

/// Canonical mechanism name strings for SCRAM variants.
enum SCRAMMechanismName {
    static let sha256 = "SCRAM-SHA-256"
    static let sha256Plus = "SCRAM-SHA-256-PLUS"
    static let sha1 = "SCRAM-SHA-1"
    static let sha1Plus = "SCRAM-SHA-1-PLUS"
}

/// Generic SCRAM mechanism (RFC 5802 / RFC 7677).
///
/// Parameterized by hash function (`SHA256` or `Insecure.SHA1`).
struct SCRAM<H: HashFunction> where H.Digest: Sendable {
    let mechanismName: String
    private var state: SCRAMState<H>

    /// A `-PLUS` mechanism takes `.bound`; the others take `.none` or `.clientSupportsButNotUsed`.
    init(
        mechanismName: String,
        channelBindingMode: ChannelBindingMode = .none,
        nonceGenerator: @Sendable @escaping () -> String = SCRAMState<H>.randomNonce
    ) {
        self.mechanismName = mechanismName
        self.state = SCRAMState(channelBindingMode: channelBindingMode, nonceGenerator: nonceGenerator)
    }

    mutating func start(authcid: String, password: String) -> XMLElement {
        let message = state.clientFirstMessage(authcid: authcid, password: password)
        var auth = XMLElement(name: "auth", namespace: saslNamespace, attributes: ["mechanism": mechanismName])
        auth.addText(Base64.encode(message))
        return auth
    }

    mutating func handleChallenge(_ challenge: XMLElement) -> SASLAuthResponse {
        guard let encoded = challenge.textContent,
              let decoded = Base64.decodeString(encoded)
        else {
            return .failure(.invalidBase64)
        }

        switch state.clientFinalMessage(serverFirstMessage: decoded) {
        case let .success(response):
            var element = XMLElement(name: "response", namespace: saslNamespace)
            element.addText(Base64.encode(response))
            return .continueWith(element)
        case let .failure(error):
            return .failure(error)
        }
    }

    mutating func handleSuccess(_ success: XMLElement) -> SASLAuthResponse {
        guard let encoded = success.textContent,
              let decoded = Base64.decodeString(encoded)
        else {
            return .failure(.invalidBase64)
        }

        switch state.verifyServerFinal(serverFinalMessage: decoded) {
        case .success:
            return .success
        case let .failure(error):
            return .failure(error)
        }
    }
}
