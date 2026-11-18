import Logging

private let log = Logger(label: "im.ducko.xmpp.jingle")

/// The IBB stanzas this side sends on a stream (XEP-0047 §2).
extension JingleModule {
    /// Sends a file's bytes in band on the session the send started on, opening its stream first if needed.
    func sendIBBData(
        sid: String, source: some JingleFileSource, totalBytes: Int64, ibbState: IBBSessionState, start: SendStart
    ) async throws {
        let (offerID, peer, context) = (start.offerID, start.peer, start.context)
        // Send IBB open handshake if not yet sent
        let needsOpen = state.withLock { state in
            Self.session(sid, offerID: offerID, in: state) != nil && state.resources[sid]?.ibb?.hasOpened == false
        }
        if needsOpen {
            try await sendIBBOpen(ibbSID: ibbState.ibbSID, blockSize: ibbState.blockSize, peer: peer, context: context)
            state.withLock { state in
                guard Self.session(sid, offerID: offerID, in: state) != nil else { return }
                state.resources[sid]?.ibb?.hasOpened = true
            }
        }

        let blockSize = Int64(ibbState.blockSize)
        var offset: Int64 = 0
        var seq: UInt16 = 0

        while offset < totalBytes {
            let chunk = try await source.nextChunk(upTo: Int(min(blockSize, totalBytes - offset)))
            // In band, ending the session closes no socket under the send, so the send checks for its session itself.
            // The check follows the read, so a stop that lands while the block is read sends nothing more.
            guard state.withLock({ Self.session(sid, offerID: offerID, in: $0) != nil }) else { throw JingleError.sessionNotFound }
            try await sendIBBChunk(ibbSID: ibbState.ibbSID, seq: seq, chunk: chunk, peer: peer, context: context)
            offset += Int64(chunk.count)
            seq &+= 1
            recordProgress(sid: sid, offerID: offerID, bytesTransferred: offset, totalBytes: totalBytes, context: context)
        }

        // Every block was acknowledged, so the receiver holds the file whether or not the close reaches it. Its
        // confirmation, not the close, decides how the send ends.
        do {
            try await sendIBBClose(ibbSID: ibbState.ibbSID, peer: peer, context: context)
        } catch {
            log.debug("IBB close failed after every block was acknowledged, sid: \(sid): \(error)")
        }
    }

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
