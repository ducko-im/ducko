import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.oob")

/// Implements XEP-0066 Out-of-Band Data (IQ-based) — handles incoming
/// IQ-set file transfer offers and provides accept/reject API.
public final class OOBModule: XMPPModule, Sendable {
    private struct PendingOffer {
        let iqID: String
        let from: JID
        let originalQuery: XMLElement
        /// Set while an answer is being sent. The offer stays listed meanwhile, so its sender's id stays reserved and a
        /// second answer cannot start.
        var isAnswering = false
    }

    private struct State {
        var context: ModuleContext?
        /// Keyed by the id this side gave each offer, since a stanza id is only unique per sender.
        var pendingOffers: [String: PendingOffer] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.oobIQ]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleDisconnect() async {
        state.withLock { $0.pendingOffers.removeAll() }
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws -> Bool {
        guard iq.isSet,
              let child = iq.childElement,
              child.name == "query",
              child.namespace == XMPPNamespaces.oobIQ, let stanzaID = iq.id,
              let from = iq.from,
              let url = child.child(named: "url")?.textContent,
              !url.isEmpty else {
            return false
        }

        let desc = child.child(named: "desc")?.textContent
        let offerID = makeOfferID()
        let admission = state.withLock { s -> (context: ModuleContext?, isDuplicate: Bool) in
            // A second request under an id the sender still awaits an answer to would leave one answer for two offers.
            guard !s.pendingOffers.values.contains(where: { $0.iqID == stanzaID && $0.from == from }) else {
                return (s.context, true)
            }
            s.pendingOffers[offerID] = PendingOffer(iqID: stanzaID, from: from, originalQuery: child)
            return (s.context, false)
        }

        if admission.isDuplicate {
            log.debug("Refusing an OOB IQ offer that reuses a pending id")
            if let context = admission.context {
                refuseDuplicate(id: stanzaID, from: from, query: child, context: context)
            }
            return true
        }

        let offer = OOBIQOffer(offerID: offerID, id: stanzaID, from: from, url: url, desc: desc)
        admission.context?.emitEvent(.oobIQOfferReceived(offer))
        log.debug("OOB IQ offer received from \(from): \(url)")
        return true
    }

    private func refuseDuplicate(id: String, from: JID, query: XMLElement, context: ModuleContext) {
        Task {
            do {
                try await context.sendStanza(
                    XMPPIQ.errorReply(id: id, to: from, payload: query, type: .cancel, condition: .conflict)
                )
            } catch {
                log.warning("Failed to refuse an OOB IQ offer: \(error)")
            }
        }
    }

    // MARK: - Public API

    /// Accepts an OOB IQ offer by responding with an IQ result.
    public func acceptOffer(offerID: String) async throws {
        guard let taken = takeOffer(offerID) else { return }
        let (context, pending) = taken

        let result = XMPPIQ(type: .result, to: pending.from, id: pending.iqID)
        // Nothing retries an acknowledgement, so an offer whose acknowledgement failed is not kept for one.
        try await send(result, offerID: offerID, keepOnFailure: false, context: context)
        log.info("Accepted OOB IQ offer \(offerID)")
    }

    /// Rejects an OOB IQ offer by responding with a not-acceptable error.
    public func rejectOffer(offerID: String) async throws {
        guard let taken = takeOffer(offerID) else { return }
        let (context, pending) = taken

        let errorIQ = XMPPIQ.errorReply(
            id: pending.iqID, to: pending.from, payload: pending.originalQuery, type: .modify, condition: .notAcceptable
        )
        try await send(errorIQ, offerID: offerID, keepOnFailure: true, context: context)
        log.info("Rejected OOB IQ offer \(offerID)")
    }

    /// Marks the offer as being answered, so a second answer cannot start while this one is sent.
    private func takeOffer(_ offerID: String) -> (ModuleContext, PendingOffer)? {
        state.withLock { s in
            guard let context = s.context, var pending = s.pendingOffers[offerID], !pending.isAnswering else { return nil }
            pending.isAnswering = true
            s.pendingOffers[offerID] = pending
            return (context, pending)
        }
    }

    /// Sends an answer and then retires the offer. An answer that could not be sent leaves the offer answerable again
    /// when `keepOnFailure` is set, and retires it otherwise.
    private func send(_ answer: XMPPIQ, offerID: String, keepOnFailure: Bool, context: ModuleContext) async throws {
        do {
            try await context.sendStanza(answer)
        } catch {
            state.withLock { s in
                if keepOnFailure {
                    s.pendingOffers[offerID]?.isAnswering = false
                } else {
                    s.pendingOffers[offerID] = nil
                }
            }
            throw error
        }
        state.withLock { $0.pendingOffers[offerID] = nil }
    }
}
