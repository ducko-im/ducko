import CryptoKit

/// Canonical mechanism name strings for SCRAM variants.
enum SCRAMMechanismName {
    static let sha3_512 = "SCRAM-SHA3-512"
    static let sha3_512Plus = "SCRAM-SHA3-512-PLUS"
    static let sha512 = "SCRAM-SHA-512"
    static let sha512Plus = "SCRAM-SHA-512-PLUS"
    static let sha256 = "SCRAM-SHA-256"
    static let sha256Plus = "SCRAM-SHA-256-PLUS"
    static let sha1 = "SCRAM-SHA-1"
    static let sha1Plus = "SCRAM-SHA-1-PLUS"
}

/// One SCRAM exchange (RFC 5802), whatever hash its mechanism uses.
protocol SCRAMSession: Sendable {
    mutating func clientFirstMessage(authcid: String, password: String) -> String
    mutating func clientFinalMessage(serverFirstMessage: String) -> Result<String, SASLAuthError>
    mutating func verifyServerFinal(serverFinalMessage: String) -> Result<Void, SASLAuthError>
}

/// The SCRAM exchange for the mechanism `name`, or nil when `name` is not a SCRAM mechanism. A `-PLUS` mechanism takes
/// `.bound`; the others take `.none` or `.clientSupportsButNotUsed`.
func makeSCRAMSession(
    _ name: String,
    channelBinding: ChannelBindingMode,
    downgradeContext: SCRAMDowngradeContext
) -> (any SCRAMSession)? {
    switch name {
    case SCRAMMechanismName.sha3_512Plus, SCRAMMechanismName.sha3_512:
        SCRAMState<SHA3_512>(channelBindingMode: channelBinding, downgradeContext: downgradeContext)
    case SCRAMMechanismName.sha512Plus, SCRAMMechanismName.sha512:
        SCRAMState<SHA512>(channelBindingMode: channelBinding, downgradeContext: downgradeContext)
    case SCRAMMechanismName.sha256Plus, SCRAMMechanismName.sha256:
        SCRAMState<SHA256>(channelBindingMode: channelBinding, downgradeContext: downgradeContext)
    case SCRAMMechanismName.sha1Plus, SCRAMMechanismName.sha1:
        SCRAMState<Insecure.SHA1>(channelBindingMode: channelBinding, downgradeContext: downgradeContext)
    default:
        nil
    }
}

/// A SCRAM mechanism (RFC 5802 / RFC 7677) framed for SASL1.
struct SCRAM {
    let mechanismName: String
    private var session: any SCRAMSession

    init(mechanismName: String, session: any SCRAMSession) {
        self.mechanismName = mechanismName
        self.session = session
    }

    mutating func start(authcid: String, password: String) -> XMLElement {
        let message = session.clientFirstMessage(authcid: authcid, password: password)
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

        switch session.clientFinalMessage(serverFirstMessage: decoded) {
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

        switch session.verifyServerFinal(serverFinalMessage: decoded) {
        case .success:
            return .success
        case let .failure(error):
            return .failure(error)
        }
    }
}
