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

    /// Parses `<mechanisms>` from stream features, selects the mechanism for `secret`, and produces the initial `<auth>`
    /// element. A bearer token goes out only over TLS and only with OAUTHBEARER. For a password, unless `allowsPLAIN`,
    /// an offer that leaves only PLAIN is refused. `tlsVersion` is the negotiated TLS version's wire code, which a
    /// SCRAM server may confirm (XEP-0515).
    mutating func begin(
        features: XMLElement,
        authcid: String,
        secret: SignInSecret,
        tlsActive: Bool,
        channelBindings: [ChannelBindingType: [UInt8]] = [:],
        tlsVersion: UInt16? = nil,
        allowsPLAIN: Bool = false
    ) throws(SASLAuthError) -> XMLElement {
        let offeredNames = Self.parseMechanisms(features)
        let password: String
        switch secret {
        case let .bearerToken(token):
            let start = try SASLOAuthBearer.start(token: token, offered: offeredNames, tlsActive: tlsActive)
            activeMechanism = .oauthBearer(start.bearer)
            var auth = XMLElement(name: "auth", namespace: saslNamespace, attributes: ["mechanism": start.mechanism])
            auth.addText(Base64.encode(start.initialResponse))
            return auth
        case let .password(value):
            password = value
        }

        try refuseBrowserOnlyOffer(offeredNames)
        let channelBinding = try chooseChannelBinding(
            bindings: channelBindings,
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

        if let session = makeSCRAMSession(selected, channelBinding: channelBinding, downgradeContext: downgradeContext) {
            var scram = SCRAM(mechanismName: selected, session: session)
            let auth = scram.start(authcid: authcid, password: password)
            activeMechanism = .scram(scram)
            return auth
        }
        guard selected == SASLPlain.mechanismName else {
            preconditionFailure("Unsupported mechanism \(selected) passed to begin")
        }
        var plain = SASLPlain()
        let auth = plain.start(authcid: authcid, password: password)
        activeMechanism = .plain(plain)
        return auth
    }

    /// Dispatches a received stanza (`<challenge>`, `<success>`, or `<failure>`) to the active mechanism.
    mutating func receive(_ stanza: XMLElement) -> SASLAuthResponse {
        guard var mechanism = activeMechanism else {
            return .failure(.unexpectedReply)
        }

        let response: SASLAuthResponse = switch stanza.name {
        case "challenge":
            mechanism.handleChallenge(stanza)
        case "success":
            mechanism.handleSuccess(stanza)
        case "failure":
            mechanism.handleFailure(stanza)
        default:
            .failure(.unknownReply(element: stanza.name))
        }
        if case .success = response {
            verifiedSCRAMMechanism = mechanism.scramMechanismName
        }

        activeMechanism = mechanism
        return response
    }

    /// Extracts `<mechanism>NAME</mechanism>` children from `<mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl">`. Names uppercased per RFC 4422 §3.1.
    static func parseMechanisms(_ features: XMLElement) -> Set<String> {
        Set(advertisedSASL1Mechanisms(features).map { $0.uppercased() })
    }

    // MARK: - Active Mechanism

    /// Enum-based dispatch for SASL mechanism types.
    enum ActiveMechanism {
        case scram(SCRAM)
        case plain(SASLPlain)
        case oauthBearer(SASLOAuthBearer)

        /// Its name when it is SCRAM, whose success carries the server's proof of knowing the password.
        var scramMechanismName: String? {
            switch self {
            case let .scram(m): m.mechanismName
            case .plain, .oauthBearer: nil
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
            case var .oauthBearer(m):
                let result = m.respond(to: challenge, namespace: saslNamespace)
                self = .oauthBearer(m)
                switch result {
                case let .success(response): return .continueWith(response)
                case let .failure(error): return .failure(error)
                }
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
            case let .oauthBearer(m):
                return m.handleSuccess().map(SASLAuthResponse.failure) ?? .success
            }
        }

        func handleFailure(_ failure: XMLElement) -> SASLAuthResponse {
            switch self {
            case .scram, .plain: .failure(.parse(failure: failure))
            case let .oauthBearer(m): .failure(m.handleFailure(failure))
            }
        }
    }
}
