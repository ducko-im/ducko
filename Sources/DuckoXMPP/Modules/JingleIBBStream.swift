/// The IBB stanzas this side sends on a stream (XEP-0047 §2).
extension JingleModule {
    func sendIBBOpen(
        ibbSID: String, blockSize: Int,
        peer: FullJID, context: ModuleContext
    ) async throws {
        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        let open = XMLElement(
            name: "open",
            namespace: XMPPNamespaces.ibb,
            attributes: ["sid": ibbSID, "block-size": String(blockSize), "stanza": "iq"]
        )
        iq.element.addChild(open)
        try await sendJingleIQ(iq, context: context, failure: JingleError.transportFailed)
    }

    func sendIBBClose(
        ibbSID: String,
        peer: FullJID, context: ModuleContext
    ) async throws {
        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        let close = XMLElement(
            name: "close",
            namespace: XMPPNamespaces.ibb,
            attributes: ["sid": ibbSID]
        )
        iq.element.addChild(close)
        try await sendJingleIQ(iq, context: context, failure: JingleError.transportFailed)
    }

    func sendIBBChunk(
        ibbSID: String, seq: UInt16, chunk: [UInt8],
        peer: FullJID, context: ModuleContext
    ) async throws {
        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        var dataElement = XMLElement(
            name: "data",
            namespace: XMPPNamespaces.ibb,
            attributes: ["sid": ibbSID, "seq": String(seq)]
        )
        dataElement.addText(Base64.encode(chunk))
        iq.element.addChild(dataElement)
        try await sendJingleIQ(iq, context: context, failure: JingleError.transportFailed)
    }
}

extension IBBSessionState {
    /// Takes a smaller block-size the peer's transport-accept names for this stream (XEP-0261 §2). A larger one, or one
    /// for another stream, leaves the proposed size.
    mutating func adoptBlockSize(acceptedIn jingle: XMLElement) {
        guard let transport = JingleModule.transportElement(in: jingle).flatMap(IBBTransport.init(from:)),
              transport.sid == ibbSID else { return }
        blockSize = min(blockSize, transport.blockSize)
    }
}
