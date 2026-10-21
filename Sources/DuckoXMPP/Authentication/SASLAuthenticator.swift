import CryptoKit

/// Negotiation coordinator for SASL authentication.
///
/// Picks the strongest mechanism from the server's offered list,
/// drives the `<auth>` → `<challenge>` → `<response>` → `<success>` exchange.
struct SASLAuthenticator {
    private var activeMechanism: ActiveMechanism?
    /// The SCRAM mechanism whose server signature checked out, once the exchange has succeeded with one.
    private(set) var verifiedSCRAMMechanism: String?

    /// Creates an authenticator with a specific mechanism (for testing with known nonces).
    init(mechanism: ActiveMechanism? = nil) {
        self.activeMechanism = mechanism
    }

    // MARK: - Negotiation

    /// Parses `<mechanisms>` from stream features, selects the strongest available,
    /// and produces the initial `<auth>` element. `requiresSCRAM` refuses an offer that leaves only PLAIN.
    mutating func begin(
        features: XMLElement,
        authcid: String,
        password: String,
        channelBindingData: [UInt8]? = nil,
        requiresSCRAM: Bool = false
    ) throws(SASLAuthError) -> XMLElement {
        let offeredNames = parseMechanisms(features)
        let channelBinding = try chooseChannelBinding(
            bindingData: channelBindingData,
            advertisedTypes: parseChannelBindingTypes(features),
            offeredMechanisms: offeredNames,
            isSASL2: false
        )
        let selected = try selectSASLMechanism(
            offered: offeredNames, channelBinding: channelBinding, requiresSCRAM: requiresSCRAM
        )

        var mechanism = createMechanism(selected, channelBinding: channelBinding)
        let auth = mechanism.start(authcid: authcid, password: password)
        activeMechanism = mechanism
        return auth
    }

    /// Dispatches a received stanza (`<challenge>`, `<success>`, or `<failure>`) to the active mechanism.
    mutating func receive(_ stanza: XMLElement) -> SASLAuthResponse {
        guard var mechanism = activeMechanism else {
            return .failure(.invalidState("No active mechanism"))
        }

        let response: SASLAuthResponse = switch stanza.name {
        case "challenge":
            mechanism.handleChallenge(stanza)
        case "success":
            mechanism.handleSuccess(stanza)
        case "failure":
            .failure(.parse(failure: stanza))
        default:
            .failure(.invalidState("Unexpected SASL element: \(stanza.name)"))
        }
        if case .success = response {
            verifiedSCRAMMechanism = mechanism.scramMechanismName
        }

        activeMechanism = mechanism
        return response
    }

    private func createMechanism(
        _ name: String,
        channelBinding: ChannelBindingMode
    ) -> ActiveMechanism {
        switch name {
        case SCRAMMechanismName.sha256Plus, SCRAMMechanismName.sha256:
            return .scram256(SCRAM<SHA256>(mechanismName: name, channelBindingMode: channelBinding))
        case SCRAMMechanismName.sha1Plus, SCRAMMechanismName.sha1:
            return .scram1(SCRAM<Insecure.SHA1>(mechanismName: name, channelBindingMode: channelBinding))
        case SASLPlain.mechanismName:
            return .plain(SASLPlain())
        default:
            preconditionFailure("Unsupported mechanism \(name) passed to createMechanism")
        }
    }

    /// Extracts `<mechanism>NAME</mechanism>` children from `<mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl">`. Names uppercased per RFC 4422 §3.1.
    private func parseMechanisms(_ features: XMLElement) -> Set<String> {
        guard let mechanisms = features.child(named: "mechanisms", namespace: saslNamespace) else {
            return []
        }
        return Set(mechanisms.children(named: "mechanism").compactMap { $0.textContent?.uppercased() })
    }

    // MARK: - Active Mechanism

    /// Enum-based dispatch for SASL mechanism types.
    enum ActiveMechanism {
        case scram256(SCRAM<SHA256>)
        case scram1(SCRAM<Insecure.SHA1>)
        case plain(SASLPlain)

        /// Its name when it is SCRAM, whose success carries the server's proof of knowing the password.
        var scramMechanismName: String? {
            switch self {
            case let .scram256(m): m.mechanismName
            case let .scram1(m): m.mechanismName
            case .plain: nil
            }
        }

        mutating func start(authcid: String, password: String) -> XMLElement {
            switch self {
            case var .scram256(m):
                let result = m.start(authcid: authcid, password: password)
                self = .scram256(m)
                return result
            case var .scram1(m):
                let result = m.start(authcid: authcid, password: password)
                self = .scram1(m)
                return result
            case var .plain(m):
                let result = m.start(authcid: authcid, password: password)
                self = .plain(m)
                return result
            }
        }

        mutating func handleChallenge(_ challenge: XMLElement) -> SASLAuthResponse {
            switch self {
            case var .scram256(m):
                let result = m.handleChallenge(challenge)
                self = .scram256(m)
                return result
            case var .scram1(m):
                let result = m.handleChallenge(challenge)
                self = .scram1(m)
                return result
            case var .plain(m):
                let result = m.handleChallenge(challenge)
                self = .plain(m)
                return result
            }
        }

        mutating func handleSuccess(_ success: XMLElement) -> SASLAuthResponse {
            switch self {
            case var .scram256(m):
                let result = m.handleSuccess(success)
                self = .scram256(m)
                return result
            case var .scram1(m):
                let result = m.handleSuccess(success)
                self = .scram1(m)
                return result
            case var .plain(m):
                let result = m.handleSuccess(success)
                self = .plain(m)
                return result
            }
        }
    }
}
