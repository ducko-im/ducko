import CryptoKit

/// Parsed inline feature advertisement from SASL2 stream features.
struct SASL2Features {
    let mechanisms: Set<String>
    let supportsBind2: Bool
    /// Whether the server takes a stream-management `<resume/>` inside `<authenticate/>`.
    let supportsSM: Bool
    /// The features Bind 2 can enable inline (XEP-0386 §3.1).
    let bind2InlineFeatures: Set<String>
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
/// using the SASL2 namespace with inline Bind 2 (XEP-0386) feature negotiation.
struct SASL2Authenticator {
    /// Result of a successful SASL2 authentication.
    enum AuthResult {
        /// The `<resumed/>` answering an inline `<resume/>`. The stream keeps the JID of the session it resumes.
        case resumed(XMLElement)
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
    /// The SCRAM mechanism whose server signature checked out, even when the rest of the success reply then failed.
    private(set) var verifiedSCRAMMechanism: String?

    // MARK: - Feature Parsing

    /// Parses `<authentication xmlns='urn:xmpp:sasl:2'>` from stream features.
    static func parseFeatures(_ features: XMLElement) -> SASL2Features? {
        guard let auth = features.child(named: "authentication", namespace: XMPPNamespaces.sasl2) else {
            return nil
        }

        let mechanisms = Set(
            auth.children(named: "mechanism").compactMap { $0.textContent?.uppercased() }
        )
        guard !mechanisms.isEmpty else { return nil }

        let inline = auth.child(named: "inline")
        let bind2 = inline?.child(named: "bind", namespace: XMPPNamespaces.bind2)
        let bind2InlineFeatures = Set(
            bind2?.child(named: "inline")?.children(named: "feature").compactMap { $0.attribute("var") } ?? []
        )

        return SASL2Features(
            mechanisms: mechanisms,
            supportsBind2: bind2 != nil,
            supportsSM: inline?.child(named: "sm", namespace: XMPPNamespaces.sm) != nil,
            bind2InlineFeatures: bind2InlineFeatures
        )
    }

    // MARK: - Negotiation

    /// Selects the strongest mechanism and produces the `<authenticate>` element.
    /// The `inlinePayloads` are added as children (e.g., Bind 2 request). `requiresSCRAM` refuses an offer that leaves
    /// only PLAIN.
    mutating func begin(
        features: XMLElement,
        authcid: String,
        password: String,
        inlinePayloads: [XMLElement],
        userAgent: SASL2UserAgent = SASL2UserAgent(),
        channelBindingData: [UInt8]? = nil,
        requiresSCRAM: Bool = false
    ) throws(SASLAuthError) -> XMLElement {
        guard let sasl2Features = Self.parseFeatures(features) else {
            throw SASLAuthError.noSupportedMechanism
        }

        let channelBinding = try chooseChannelBinding(
            bindingData: channelBindingData,
            advertisedTypes: parseChannelBindingTypes(features),
            offeredMechanisms: sasl2Features.mechanisms,
            isSASL2: true
        )
        let selected = try selectSASLMechanism(
            offered: sasl2Features.mechanisms, channelBinding: channelBinding, requiresSCRAM: requiresSCRAM
        )

        let (mechanism, initialPayload) = startMechanism(
            selected, authcid: authcid, password: password, channelBinding: channelBinding
        )
        activeMechanism = mechanism
        mechanismName = selected

        var authenticate = XMLElement(
            name: "authenticate",
            namespace: XMPPNamespaces.sasl2,
            attributes: ["mechanism": selected]
        )

        var initialResponse = XMLElement(name: "initial-response")
        initialResponse.addText(Base64.encode(initialPayload))
        authenticate.addChild(initialResponse)
        authenticate.addChild(userAgent.element)

        for payload in inlinePayloads {
            authenticate.addChild(payload)
        }

        return authenticate
    }

    /// Dispatches a received stanza (`<challenge>`, `<success>`, or `<failure>`) to the active mechanism.
    mutating func receive(_ stanza: XMLElement) -> Response {
        guard var mechanism = activeMechanism else {
            return .failure(.invalidState("No active mechanism"))
        }

        let response: Response = switch stanza.name {
        case "challenge":
            handleChallenge(stanza, mechanism: &mechanism)
        case "success":
            handleSuccess(stanza, mechanism: &mechanism)
        case "failure":
            .failure(.parse(failure: stanza))
        case "continue":
            .failure(.unsupportedSignInStep)
        default:
            .failure(.invalidState("Unexpected SASL2 element: \(stanza.name)"))
        }

        activeMechanism = mechanism
        return response
    }

    // MARK: - Private: Mechanism Dispatch

    private func startMechanism(
        _ name: String,
        authcid: String,
        password: String,
        channelBinding: ChannelBindingMode
    ) -> (ActiveMechanism, String) {
        switch name {
        case SCRAMMechanismName.sha256Plus, SCRAMMechanismName.sha256:
            var scram = SCRAMState<SHA256>(channelBindingMode: channelBinding)
            let payload = scram.clientFirstMessage(authcid: authcid, password: password)
            return (.scram256(scram), payload)
        case SCRAMMechanismName.sha1Plus, SCRAMMechanismName.sha1:
            var scram = SCRAMState<Insecure.SHA1>(channelBindingMode: channelBinding)
            let payload = scram.clientFirstMessage(authcid: authcid, password: password)
            return (.scram1(scram), payload)
        case SASLPlain.mechanismName:
            let payload = "\0\(authcid)\0\(password)"
            return (.plain, payload)
        default:
            preconditionFailure("Unsupported mechanism \(name) passed to startMechanism")
        }
    }

    private func handleChallenge(_ stanza: XMLElement, mechanism: inout ActiveMechanism) -> Response {
        guard let encoded = stanza.textContent,
              let decoded = Base64.decodeString(encoded) else {
            return .failure(.invalidBase64)
        }

        switch mechanism {
        case var .scram256(scram):
            let response = scramChallengeResponse(decoded, scram: &scram)
            mechanism = .scram256(scram)
            return response
        case var .scram1(scram):
            let response = scramChallengeResponse(decoded, scram: &scram)
            mechanism = .scram1(scram)
            return response
        case .plain:
            return .failure(.invalidState("PLAIN does not expect challenges"))
        }
    }

    private mutating func handleSuccess(_ stanza: XMLElement, mechanism: inout ActiveMechanism) -> Response {
        // Verify SCRAM server signature from <additional-data> (required for SCRAM mechanisms)
        switch mechanism {
        case var .scram256(scram):
            if let error = verifyScramSignature(stanza, scram: &scram) { return error }
            mechanism = .scram256(scram)
            verifiedSCRAMMechanism = mechanismName
        case var .scram1(scram):
            if let error = verifyScramSignature(stanza, scram: &scram) { return error }
            mechanism = .scram1(scram)
            verifiedSCRAMMechanism = mechanismName
        case .plain:
            break
        }

        return parseSuccess(stanza)
    }

    /// Processes a SCRAM challenge and produces the response element.
    private func scramChallengeResponse<H: HashFunction>(
        _ decoded: String,
        scram: inout SCRAMState<H>
    ) -> Response where H.Digest: Sendable {
        switch scram.clientFinalMessage(serverFirstMessage: decoded) {
        case let .success(response):
            var element = XMLElement(name: "response", namespace: XMPPNamespaces.sasl2)
            element.addText(Base64.encode(response))
            return .continueWith(element)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Verifies the SCRAM server signature from `<additional-data>`.
    /// Returns an error response if verification fails, `nil` on success.
    private func verifyScramSignature<H: HashFunction>(
        _ stanza: XMLElement,
        scram: inout SCRAMState<H>
    ) -> Response? where H.Digest: Sendable {
        guard let additionalData = stanza.childText(named: "additional-data"),
              let decoded = Base64.decodeString(additionalData) else {
            return .failure(.invalidState("Missing additional-data for SCRAM server verification"))
        }
        let result = scram.verifyServerFinal(serverFinalMessage: decoded)
        if case let .failure(error) = result { return .failure(error) }
        return nil
    }

    /// Parses a SASL2 success into a resumed stream or a new session. A resumed stream may name only the bare JID
    /// (XEP-0388 Example 9); a new session must name its full JID.
    private func parseSuccess(_ stanza: XMLElement) -> Response {
        let jid = stanza.childText(named: "authorization-identifier")
        if let resumed = stanza.child(named: "resumed", namespace: XMPPNamespaces.sm),
           let jid, JID.parse(jid) != nil {
            return .success(.resumed(resumed))
        }
        guard let fullJID = jid.flatMap(FullJID.parse) else {
            return .failure(.invalidState("No valid account address in the success reply"))
        }
        return .success(.session(fullJID, bound: stanza.child(named: "bound", namespace: XMPPNamespaces.bind2)))
    }

    // MARK: - Active Mechanism

    private enum ActiveMechanism {
        case scram256(SCRAMState<SHA256>)
        case scram1(SCRAMState<Insecure.SHA1>)
        case plain
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
