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
    /// and produces the initial `<auth>` element. Unless `allowsPLAIN`, an offer that leaves only PLAIN is refused.
    /// `tlsVersion` is the negotiated TLS version's wire code, which a SCRAM server may confirm (XEP-0515).
    mutating func begin(
        features: XMLElement,
        authcid: String,
        password: String,
        channelBindingData: [UInt8]? = nil,
        tlsVersion: UInt16? = nil,
        allowsPLAIN: Bool = false
    ) throws(SASLAuthError) -> XMLElement {
        let offeredNames = parseMechanisms(features)
        let channelBinding = try chooseChannelBinding(
            bindingData: channelBindingData,
            advertisedTypes: parseChannelBindingTypes(features),
            offeredMechanisms: offeredNames,
            isSASL2: false
        )
        let selected = try selectSASLMechanism(
            offered: offeredNames, channelBinding: channelBinding, allowsPLAIN: allowsPLAIN
        )
        let downgradeContext = SCRAMDowngradeContext(
            advertisedMechanisms: advertisedSASL1Mechanisms(features),
            channelBindingTypes: advertisedChannelBindingTypeList(features),
            tlsVersion: tlsVersion
        )

        var mechanism = createMechanism(selected, channelBinding: channelBinding, downgradeContext: downgradeContext)
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
        channelBinding: ChannelBindingMode,
        downgradeContext: SCRAMDowngradeContext
    ) -> ActiveMechanism {
        if let session = makeSCRAMSession(name, channelBinding: channelBinding, downgradeContext: downgradeContext) {
            return .scram(SCRAM(mechanismName: name, session: session))
        }
        guard name == SASLPlain.mechanismName else {
            preconditionFailure("Unsupported mechanism \(name) passed to createMechanism")
        }
        return .plain(SASLPlain())
    }

    /// Extracts `<mechanism>NAME</mechanism>` children from `<mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl">`. Names uppercased per RFC 4422 §3.1.
    private func parseMechanisms(_ features: XMLElement) -> Set<String> {
        Set(advertisedSASL1Mechanisms(features).map { $0.uppercased() })
    }

    // MARK: - Active Mechanism

    /// Enum-based dispatch for SASL mechanism types.
    enum ActiveMechanism {
        case scram(SCRAM)
        case plain(SASLPlain)

        /// Its name when it is SCRAM, whose success carries the server's proof of knowing the password.
        var scramMechanismName: String? {
            switch self {
            case let .scram(m): m.mechanismName
            case .plain: nil
            }
        }

        mutating func start(authcid: String, password: String) -> XMLElement {
            switch self {
            case var .scram(m):
                let result = m.start(authcid: authcid, password: password)
                self = .scram(m)
                return result
            case var .plain(m):
                let result = m.start(authcid: authcid, password: password)
                self = .plain(m)
                return result
            }
        }

        mutating func handleChallenge(_ challenge: XMLElement) -> SASLAuthResponse {
            switch self {
            case var .scram(m):
                let result = m.handleChallenge(challenge)
                self = .scram(m)
                return result
            case var .plain(m):
                let result = m.handleChallenge(challenge)
                self = .plain(m)
                return result
            }
        }

        mutating func handleSuccess(_ success: XMLElement) -> SASLAuthResponse {
            switch self {
            case var .scram(m):
                let result = m.handleSuccess(success)
                self = .scram(m)
                return result
            case var .plain(m):
                let result = m.handleSuccess(success)
                self = .plain(m)
                return result
            }
        }
    }
}
