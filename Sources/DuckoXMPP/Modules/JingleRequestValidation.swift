/// The checks that decide which error a Jingle or IBB request gets before this side acknowledges or handles it.
extension JingleModule {
    /// Why a Jingle request gets an error instead of being handled.
    enum RequestRefusal {
        /// The request is malformed (XEP-0166 §6.3.2, §7.2).
        case badRequest
        /// An informational payload this side does not process (XEP-0166 §6.8).
        case unsupportedInfo
        /// The request clashes with a session or transport already under way: a session-initiate for a live sid, or the
        /// responder's transport-replace while this side's own is pending, where the initiator's wins (XEP-0166 §7.2).
        case tieBreak
    }

    /// A transport-info payload this side acts on (XEP-0260 §2.3-2.5).
    enum TransportInfoPayload {
        case candidateUsed(cid: String)
        case candidateError
        case proxyError
        case activated(cid: String?)

        init?(in jingle: XMLElement) {
            guard let transport = JingleModule.transportElement(in: jingle) else { return nil }
            if let cid = transport.child(named: "candidate-used")?.attribute("cid") {
                self = .candidateUsed(cid: cid)
            } else if transport.child(named: "candidate-error") != nil {
                self = .candidateError
            } else if transport.child(named: "proxy-error") != nil {
                self = .proxyError
            } else if let activated = transport.child(named: "activated") {
                self = .activated(cid: activated.attribute("cid"))
            } else {
                return nil
            }
        }
    }

    /// The parts of an IBB `<open/>` (XEP-0047 §2.1) this side checks before taking the stream.
    struct IBBOpenRequest {
        let ibbSID: String
        let blockSize: Int
        /// Whether the peer would send its data in message stanzas, which this side does not read.
        let usesMessages: Bool

        init?(from element: XMLElement) {
            guard let ibbSID = element.attribute("sid"), let blockSize = IBBTransport.blockSize(of: element) else { return nil }
            switch element.attribute("stanza") ?? "iq" {
            case "iq": self.usesMessages = false
            case "message": self.usesMessages = true
            default: return nil
            }
            self.ibbSID = ibbSID
            self.blockSize = blockSize
        }
    }

    /// The error a request earns before it is acknowledged, or `nil` when it can be handled.
    func refusal(of jingle: XMLElement, action: JingleAction, sid: String) -> RequestRefusal? {
        // Only the initiator proposes a transport-replace, so a pending one makes this side the initiator.
        if action == .transportReplace, state.withLock({ Self.isReplacePending(sid: sid, in: $0) }) {
            return .tieBreak
        }
        return Self.payloadRefusal(of: jingle, action: action)
    }

    /// Whether this side proposed a transport-replace the peer has not yet answered. Must be called within a
    /// state.withLock.
    static func isReplacePending(sid: String, in state: State) -> Bool {
        guard case .replacePending? = state.resources[sid]?.session?.transportState else { return false }
        return true
    }

    /// The error a request's payload earns before it is acknowledged, or `nil` when the payload can be handled.
    private static func payloadRefusal(of jingle: XMLElement, action: JingleAction) -> RequestRefusal? {
        switch action {
        case .sessionInitiate:
            isWellFormedInitiate(jingle) ? nil : .badRequest
        case .sessionInfo:
            understandsSessionInfo(jingle) ? nil : .unsupportedInfo
        case .transportInfo:
            TransportInfoPayload(in: jingle) == nil ? .unsupportedInfo : nil
        case .sessionAccept, .sessionTerminate, .transportReplace, .transportAccept, .transportReject,
             .contentAdd, .contentAccept, .contentModify, .contentReject, .contentRemove, .descriptionInfo, .securityInfo:
            nil
        }
    }

    /// Whether every content of a session-initiate names its creator and name and holds a description and a transport,
    /// and at least one content takes the default `session` disposition (XEP-0166 §7.2).
    private static func isWellFormedInitiate(_ jingle: XMLElement) -> Bool {
        let contents = jingle.children(named: "content")
        let isComplete = contents.allSatisfy { content in
            content.attribute("creator") != nil && content.attribute("name") != nil
                && content.child(named: "description") != nil && content.child(named: "transport") != nil
        }
        return isComplete && contents.contains { ($0.attribute("disposition") ?? "session") == "session" }
    }

    /// Whether every session-info payload is one XEP-0234 defines. An empty session-info is a ping (XEP-0166 §6.8).
    private static func understandsSessionInfo(_ jingle: XMLElement) -> Bool {
        jingle.children.allSatisfy { node in
            guard case let .element(payload) = node else { return true }
            return payload.namespace == XMPPNamespaces.jingleFileTransfer && ["checksum", "received"].contains(payload.name)
        }
    }

    /// The SOCKS5 or IBB transport a Jingle request carries, inside its content or directly under `<jingle>`.
    static func transportElement(in jingle: XMLElement) -> XMLElement? {
        let parents = [jingle.child(named: "content"), jingle].compactMap(\.self)
        for parent in parents {
            for namespace in [XMPPNamespaces.jingleS5B, XMPPNamespaces.jingleIBB] {
                if let transport = parent.child(named: "transport", namespace: namespace) { return transport }
            }
        }
        return nil
    }

    func reply(_ refusal: RequestRefusal, to iq: XMPPIQ, context: ModuleContext) {
        switch refusal {
        case .badRequest:
            replyBadRequest(to: iq, context: context)
        case .unsupportedInfo:
            replyError(to: iq, type: .cancel, condition: .featureNotImplemented, jingleCondition: .unsupportedInfo, context: context)
        case .tieBreak:
            replyError(to: iq, type: .cancel, condition: .conflict, jingleCondition: .tieBreak, context: context)
        }
    }

    func replyBadRequest(to iq: XMPPIQ, context: ModuleContext) {
        replyError(to: iq, type: .cancel, condition: .badRequest, context: context)
    }

    /// Takes an open for a known stream, unless it would carry its data in messages or in larger blocks than the
    /// transport negotiated (XEP-0047 §2.1).
    func answer(_ open: IBBOpenRequest, negotiatedBlockSize: Int, to iq: XMPPIQ, context: ModuleContext) {
        if open.usesMessages {
            replyError(to: iq, type: .cancel, condition: .notAcceptable, context: context)
        } else if open.blockSize > negotiatedBlockSize {
            replyError(to: iq, type: .modify, condition: .resourceConstraint, context: context)
        } else {
            acknowledgeIQ(iq, context: context)
        }
    }
}
