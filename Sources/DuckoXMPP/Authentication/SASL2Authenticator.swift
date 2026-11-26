/// Parsed inline feature advertisement from SASL2 stream features.
struct SASL2Features {
    let mechanisms: Set<String>
    let supportsBind2: Bool
    /// Whether the server takes a stream-management `<resume/>` inside `<authenticate/>`.
    let supportsSM: Bool
    /// The features Bind 2 can enable inline (XEP-0386 §3.1).
    let bind2InlineFeatures: Set<String>
    /// The upgrade tasks the server offers (XEP-0480 §2.1), uppercased.
    let upgrades: Set<String>
}

/// The `<user-agent/>` a SASL2 `<authenticate/>` carries (XEP-0388 §2.3). It has no id, so the server gives every
/// connection its own resource rather than one that a second connection to the account would take over.
public struct SASL2UserAgent: Sendable {
    public let software: String
    public let device: String?

    public init(software: String = "Ducko", device: String? = nil) {
        self.software = software
        self.device = device
    }

    var element: XMLElement {
        var userAgent = XMLElement(name: "user-agent")
        var softwareElement = XMLElement(name: "software")
        softwareElement.addText(software)
        userAgent.addChild(softwareElement)
        if let device {
            var deviceElement = XMLElement(name: "device")
            deviceElement.addText(device)
            userAgent.addChild(deviceElement)
        }
        return userAgent
    }
}

/// Negotiation coordinator for SASL2 authentication (XEP-0388).
///
/// Drives the `<authenticate>` → `<challenge>` → `<response>` → `<success>` exchange
/// using the SASL2 namespace with inline Bind 2 (XEP-0386) feature negotiation. When `<authenticate>` asks for a SCRAM
/// upgrade (XEP-0480), the server may answer the proof with `<continue>`. The `<next>` → `<task-data>` → `<task-data>`
/// exchange then runs before `<success>`.
struct SASL2Authenticator {
    /// Result of a successful SASL2 authentication.
    enum AuthResult {
        /// The `<resumed/>` answering an inline `<resume/>`, with the `<authorization-identifier>` the success named. The
        /// stream keeps the JID of the session it resumes.
        case resumed(XMLElement, identifier: JID)
        case session(FullJID, bound: XMLElement?)
    }

    /// Result of a SASL2 exchange step.
    enum Response {
        case continueWith(XMLElement)
        case success(AuthResult)
        case failure(SASLAuthError)
    }

    private var activeMechanism: ActiveMechanism?
    private var mechanismName: String?
    /// The SCRAM mechanism whose server signature checked out, even when the sign-in then failed.
    private(set) var verifiedSCRAMMechanism: String?
    private var upgrade = UpgradeState.notRequested

    // MARK: - Feature Parsing

    /// Parses `<authentication xmlns='urn:xmpp:sasl:2'>` from stream features.
    static func parseFeatures(_ features: XMLElement) -> SASL2Features? {
        guard let auth = features.child(named: "authentication", namespace: XMPPNamespaces.sasl2) else {
            return nil
        }

        let mechanisms = Set(advertisedSASL2Mechanisms(features).map { $0.uppercased() })
        guard !mechanisms.isEmpty else { return nil }

        let inline = auth.child(named: "inline")
        let bind2 = inline?.child(named: "bind", namespace: XMPPNamespaces.bind2)
        let bind2InlineFeatures = Set(
            bind2?.child(named: "inline")?.children(named: "feature").compactMap { $0.attribute("var") } ?? []
        )
        let upgrades = Set(
            auth.children(named: "upgrade").filter { $0.namespace == XMPPNamespaces.saslUpgrade }
                .compactMap { $0.textContent?.uppercased() }
        )

        return SASL2Features(
            mechanisms: mechanisms,
            supportsBind2: bind2 != nil,
            supportsSM: inline?.child(named: "sm", namespace: XMPPNamespaces.sm) != nil,
            bind2InlineFeatures: bind2InlineFeatures,
            upgrades: upgrades
        )
    }

    // MARK: - Negotiation

    /// Selects the mechanism for `secret` and produces the `<authenticate>` element. A bearer token goes out only over TLS
    /// and only with OAUTHBEARER, which binds to no channel and asks for no upgrade. For a password, a channel-bound SCRAM
    /// sign-in asks for the strongest offered upgrade to a stronger hash. Unless `allowsPLAIN`, a password offer that
    /// leaves only PLAIN is refused. The `inlinePayloads` are added as children (e.g., Bind 2 request). `tlsVersion` is
    /// the negotiated TLS version's wire code, which a SCRAM server may confirm (XEP-0515).
    mutating func begin(
        features: XMLElement,
        authcid: String,
        secret: SignInSecret,
        tlsActive: Bool,
        inlinePayloads: [XMLElement],
        userAgent: SASL2UserAgent = SASL2UserAgent(),
        channelBindings: [ChannelBindingType: [UInt8]] = [:],
        tlsVersion: UInt16? = nil,
        allowsPLAIN: Bool = false
    ) throws(SASLAuthError) -> XMLElement {
        guard let sasl2Features = Self.parseFeatures(features) else {
            throw SASLAuthError.noSupportedMechanism
        }

        let selected: String
        let initialPayload: [UInt8]
        var upgradeRequest: XMLElement?
        switch secret {
        case let .bearerToken(token):
            let start = try SASLOAuthBearer.start(token: token, offered: sasl2Features.mechanisms, tlsActive: tlsActive)
            selected = start.mechanism
            initialPayload = start.initialResponse
            activeMechanism = .oauthBearer(start.bearer)
        case let .password(password):
            try refuseBrowserOnlyOffer(sasl2Features.mechanisms)
            let channelBinding = try chooseChannelBinding(
                bindings: channelBindings,
                advertisedTypes: parseChannelBindingTypes(features),
                offeredMechanisms: sasl2Features.mechanisms,
                isSASL2: true
            )
            selected = try selectSASLMechanism(
                offered: sasl2Features.mechanisms, channelBinding: channelBinding, allowsPLAIN: allowsPLAIN
            )
            let downgradeContext = SCRAMDowngradeContext(
                advertisedMechanisms: advertisedSASL2Mechanisms(features),
                channelBindingTypes: advertisedChannelBindingTypeList(features),
                tlsVersion: tlsVersion
            )
            let (mechanism, payload) = startMechanism(
                selected, authcid: authcid, password: password, channelBinding: channelBinding, downgradeContext: downgradeContext
            )
            activeMechanism = mechanism
            initialPayload = Array(payload.utf8)
            if let hash = selectSCRAMUpgrade(
                offered: sasl2Features.upgrades, selectedMechanism: selected, channelBinding: channelBinding
            ) {
                var request = XMLElement(name: "upgrade", namespace: XMPPNamespaces.saslUpgrade)
                request.addText(hash.upgradeTaskName)
                upgradeRequest = request
                upgrade = .requested(hash, password: password)
            }
        }
        mechanismName = selected
        return Self.authenticateElement(
            mechanism: selected, initialPayload: initialPayload, upgradeRequest: upgradeRequest, userAgent: userAgent,
            inlinePayloads: inlinePayloads
        )
    }

    private static func authenticateElement(
        mechanism: String, initialPayload: [UInt8], upgradeRequest: XMLElement?, userAgent: SASL2UserAgent, inlinePayloads: [XMLElement]
    ) -> XMLElement {
        var authenticate = XMLElement(
            name: "authenticate",
            namespace: XMPPNamespaces.sasl2,
            attributes: ["mechanism": mechanism]
        )
        if let upgradeRequest {
            authenticate.addChild(upgradeRequest)
        }

        var initialResponse = XMLElement(name: "initial-response")
        initialResponse.addText(Base64.encode(initialPayload))
        authenticate.addChild(initialResponse)
        authenticate.addChild(userAgent.element)

        for payload in inlinePayloads {
            authenticate.addChild(payload)
        }

        return authenticate
    }

    /// Handles the server's next SASL2 element.
    mutating func receive(_ stanza: XMLElement) -> Response {
        guard var mechanism = activeMechanism else {
            return .failure(.unexpectedReply)
        }

        let response: Response = switch stanza.name {
        case "challenge":
            handleChallenge(stanza, mechanism: &mechanism)
        case "success":
            handleSuccess(stanza, mechanism: &mechanism)
        case "failure":
            handleFailure(stanza, mechanism: mechanism)
        case "continue":
            handleContinue(stanza, mechanism: &mechanism)
        case "task-data":
            handleTaskData(stanza)
        default:
            .failure(.unknownReply(element: stanza.name))
        }

        activeMechanism = mechanism
        return response
    }

    /// Whether a failure this side found in `stanza` is answered with `<abort/>`. A server's `<success>` or `<failure>`
    /// has already ended the exchange, so only what arrives mid-exchange gets one.
    static func answersFailureWithAbort(_ stanza: XMLElement) -> Bool {
        stanza.name != "success" && stanza.name != "failure"
    }

    // MARK: - Private: Mechanism Dispatch

    private func startMechanism(
        _ name: String,
        authcid: String,
        password: String,
        channelBinding: ChannelBindingMode,
        downgradeContext: SCRAMDowngradeContext
    ) -> (ActiveMechanism, String) {
        if var scram = makeSCRAMSession(name, channelBinding: channelBinding, downgradeContext: downgradeContext) {
            let payload = scram.clientFirstMessage(authcid: authcid, password: password)
            return (.scram(scram), payload)
        }
        guard name == SASLPlain.mechanismName else {
            preconditionFailure("Unsupported mechanism \(name) passed to startMechanism")
        }
        return (.plain, "\0\(authcid)\0\(password)")
    }

    private func handleChallenge(_ stanza: XMLElement, mechanism: inout ActiveMechanism) -> Response {
        switch mechanism {
        case var .scram(scram):
            guard let encoded = stanza.textContent, let decoded = Base64.decodeString(encoded) else {
                return .failure(.invalidBase64)
            }
            let response = scramChallengeResponse(decoded, scram: &scram)
            mechanism = .scram(scram)
            return response
        case .plain:
            return .failure(.unsupportedSignInStep)
        case var .oauthBearer(bearer):
            let result = bearer.respond(to: stanza, namespace: XMPPNamespaces.sasl2)
            mechanism = .oauthBearer(bearer)
            switch result {
            case let .success(response): return .continueWith(response)
            case let .failure(error): return .failure(error)
            }
        }
    }

    private func handleFailure(_ stanza: XMLElement, mechanism: ActiveMechanism) -> Response {
        switch mechanism {
        case .scram, .plain: .failure(.parse(failure: stanza))
        case let .oauthBearer(bearer): .failure(bearer.handleFailure(stanza))
        }
    }

    private mutating func handleSuccess(_ stanza: XMLElement, mechanism: inout ActiveMechanism) -> Response {
        // A SCRAM success must carry the server signature in <additional-data>, unless a <continue> before it
        // already did.
        switch mechanism {
        case let .scram(scram):
            guard verifiedSCRAMMechanism == nil else { break }
            if let error = verifyScramSignature(stanza, scram: scram, mechanism: &mechanism) { return error }
        case .plain:
            break
        case let .oauthBearer(bearer):
            if let error = bearer.handleSuccess() { return .failure(error) }
        }

        return parseSuccess(stanza)
    }

    /// Answers the `<continue>` that follows a requested SCRAM upgrade with `<next>` (XEP-0480 §2.2). Any other
    /// `<continue>`, such as one asking for a second factor, is not supported.
    ///
    /// The server signature is checked before the task is answered, because the hash the task returns is
    /// password-equivalent. XEP-0480 does not require this order.
    private mutating func handleContinue(_ stanza: XMLElement, mechanism: inout ActiveMechanism) -> Response {
        guard case let .scram(scram) = mechanism, case let .requested(hash, password) = upgrade else {
            return .failure(.unsupportedSignInStep)
        }
        if let error = verifyScramSignature(stanza, scram: scram, mechanism: &mechanism) { return error }

        let tasks = stanza.child(named: "tasks")?.children(named: "task").map(\.textContent)
        guard tasks == [hash.upgradeTaskName] else { return .failure(.unsupportedSignInStep) }
        upgrade = .started(hash, password: password)
        return .continueWith(XMLElement(name: "next", namespace: XMPPNamespaces.sasl2, attributes: ["task": hash.upgradeTaskName]))
    }

    /// Returns the SaltedPassword for the upgraded hash that the server's salt asks for (XEP-0480 §3). Only a verified
    /// `<continue>` starts the upgrade, so a `<task-data>` that comes before or instead of one gets no hash.
    private mutating func handleTaskData(_ stanza: XMLElement) -> Response {
        guard case let .started(hash, password) = upgrade else {
            return .failure(.unexpectedReply)
        }
        switch parseSCRAMUpgradeSalt(stanza, hash: hash) {
        case let .success(parsed):
            upgrade = .notRequested
            let saltedPassword = hash.saltedPassword(password: Array(password.utf8), salt: parsed.salt, iterations: parsed.iterations)
            return .continueWith(scramUpgradeHashElement(saltedPassword))
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Processes a SCRAM challenge and produces the response element.
    private func scramChallengeResponse(_ decoded: String, scram: inout any SCRAMSession) -> Response {
        switch scram.clientFinalMessage(serverFirstMessage: decoded) {
        case let .success(response):
            var element = XMLElement(name: "response", namespace: XMPPNamespaces.sasl2)
            element.addText(Base64.encode(response))
            return .continueWith(element)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Verifies the SCRAM server signature from `<additional-data>`, returning the failure response or `nil` on success.
    /// On success it stores the completed exchange in `mechanism` and records the mechanism as verified.
    private mutating func verifyScramSignature(
        _ stanza: XMLElement, scram: any SCRAMSession, mechanism: inout ActiveMechanism
    ) -> Response? {
        guard let additionalData = stanza.childText(named: "additional-data") else {
            return .failure(.serverProofMissing)
        }
        guard let decoded = Base64.decodeString(additionalData) else {
            return .failure(.invalidBase64)
        }
        var scram = scram
        if case let .failure(error) = scram.verifyServerFinal(serverFinalMessage: decoded) { return .failure(error) }
        mechanism = .scram(scram)
        verifiedSCRAMMechanism = mechanismName
        return nil
    }

    /// Parses a SASL2 success into a resumed stream or a new session. A resumed stream may name only the bare JID
    /// (XEP-0388 Example 9); a new session must name its full JID.
    private func parseSuccess(_ stanza: XMLElement) -> Response {
        let jid = stanza.childText(named: "authorization-identifier")
        if let resumed = stanza.child(named: "resumed", namespace: XMPPNamespaces.sm),
           let identifier = jid.flatMap(JID.parse) {
            return .success(.resumed(resumed, identifier: identifier))
        }
        guard let fullJID = jid.flatMap(FullJID.parse) else {
            return .failure(.accountAddressMissing)
        }
        return .success(.session(fullJID, bound: stanza.child(named: "bound", namespace: XMPPNamespaces.bind2)))
    }

    // MARK: - Active Mechanism

    private enum ActiveMechanism {
        case scram(any SCRAMSession)
        case plain
        case oauthBearer(SASLOAuthBearer)
    }

    // MARK: - SCRAM Upgrade

    /// Where a requested SCRAM upgrade stands.
    private enum UpgradeState {
        case notRequested
        /// `<authenticate>` asked for the upgrade to this hash.
        case requested(SCRAMHash, password: String)
        /// A verified `<continue>` was answered with `<next>`, so the server's salt is due.
        case started(SCRAMHash, password: String)
    }
}

// MARK: - Bind 2

/// Builds a Bind 2 request element for inclusion in SASL2 `<authenticate>`.
func buildBind2Request(
    tag: String = "Ducko",
    enableSM: Bool = false,
    enableCarbons: Bool = false
) -> XMLElement {
    var bind = XMLElement(name: "bind", namespace: XMPPNamespaces.bind2)

    var tagElement = XMLElement(name: "tag")
    tagElement.addText(tag)
    bind.addChild(tagElement)

    if enableSM {
        bind.addChild(XMLElement(
            name: "enable",
            namespace: XMPPNamespaces.sm,
            attributes: ["resume": "true"]
        ))
    }

    if enableCarbons {
        bind.addChild(XMLElement(name: "enable", namespace: XMPPNamespaces.carbons))
    }

    return bind
}
