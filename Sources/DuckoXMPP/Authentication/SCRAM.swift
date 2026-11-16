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

/// The lowest PBKDF2 iteration count this client accepts, for every hash and for an upgrade's salt. RFC 5802 §5.1 asks
/// servers for at least 4096.
let scramMinimumIterationCount = 4096

/// One SCRAM exchange (RFC 5802), whatever hash its mechanism uses.
protocol SCRAMSession: Sendable {
    mutating func clientFirstMessage(authcid: String, password: String) -> String
    mutating func clientFinalMessage(serverFirstMessage: String) -> Result<String, SASLAuthError>
    mutating func verifyServerFinal(serverFinalMessage: String) -> Result<Void, SASLAuthError>
}

/// The hash a SCRAM mechanism uses, strongest first.
enum SCRAMHash: CaseIterable {
    case sha3_512, sha512, sha256, sha1

    /// Matches `name` with or without `-PLUS`, and fails for a mechanism this client does not implement.
    init?(mechanism name: String) {
        guard let hash = Self.allCases.first(where: { name == $0.mechanismName || name == $0.plusMechanismName }) else {
            return nil
        }
        self = hash
    }

    /// The mechanism's name without `-PLUS`.
    var mechanismName: String {
        switch self {
        case .sha3_512: SCRAMMechanismName.sha3_512
        case .sha512: SCRAMMechanismName.sha512
        case .sha256: SCRAMMechanismName.sha256
        case .sha1: SCRAMMechanismName.sha1
        }
    }

    /// The mechanism's name with `-PLUS`, which binds to the TLS channel.
    var plusMechanismName: String {
        switch self {
        case .sha3_512: SCRAMMechanismName.sha3_512Plus
        case .sha512: SCRAMMechanismName.sha512Plus
        case .sha256: SCRAMMechanismName.sha256Plus
        case .sha1: SCRAMMechanismName.sha1Plus
        }
    }

    /// The RFC 5802 SaltedPassword for this hash.
    func saltedPassword(password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        switch self {
        case .sha3_512: pbkdf2(SHA3_512.self, password: password, salt: salt, iterations: iterations)
        case .sha512: pbkdf2(SHA512.self, password: password, salt: salt, iterations: iterations)
        case .sha256: pbkdf2(SHA256.self, password: password, salt: salt, iterations: iterations)
        case .sha1: pbkdf2(Insecure.SHA1.self, password: password, salt: salt, iterations: iterations)
        }
    }
}

/// The SCRAM exchange for the mechanism `name`, or nil when `name` is not a SCRAM mechanism. A `-PLUS` mechanism takes
/// `.bound`; the others take `.none` or `.clientSupportsButNotUsed`.
func makeSCRAMSession(
    _ name: String,
    channelBinding: ChannelBindingMode,
    downgradeContext: SCRAMDowngradeContext
) -> (any SCRAMSession)? {
    switch SCRAMHash(mechanism: name) {
    case .sha3_512:
        SCRAMState<SHA3_512>(channelBindingMode: channelBinding, downgradeContext: downgradeContext)
    case .sha512:
        SCRAMState<SHA512>(channelBindingMode: channelBinding, downgradeContext: downgradeContext)
    case .sha256:
        SCRAMState<SHA256>(channelBindingMode: channelBinding, downgradeContext: downgradeContext)
    case .sha1:
        SCRAMState<Insecure.SHA1>(channelBindingMode: channelBinding, downgradeContext: downgradeContext)
    case nil:
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
        guard let encoded = success.textContent else {
            return .failure(.serverProofMissing)
        }
        guard let decoded = Base64.decodeString(encoded) else {
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
