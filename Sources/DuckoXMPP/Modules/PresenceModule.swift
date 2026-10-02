import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.presence")

/// Tracks presence for contacts and sends initial available presence on connect.
public final class PresenceModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        /// Presence map keyed by bare JID → resource → presence.
        var presences: [BareJID: [String: XMPPPresence]] = [:]
        /// Own avatar for vCard-based avatar presence broadcasts (XEP-0153).
        var ownAvatar = OwnAvatar.notReady
    }

    private enum OwnAvatar {
        /// The own avatar is not known yet, so presence must not claim there is none.
        case notReady
        case known(hash: String?)
    }

    private let state: OSAllocatedUnfairLock<State>

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var presence = XMPPPresence()
        appendAvatarHash(to: &presence)
        try await context.sendStanza(presence)
        log.info("Sent initial available presence")
    }

    public func handleDisconnect() async {
        state.withLock { $0.presences.removeAll() }
    }

    // MARK: - Dispatch

    public func handlePresence(_ presence: XMPPPresence) throws {
        guard let from = presence.from else { return }
        let context = state.withLock { $0.context }

        if let handled = handleSubscriptionPresence(from: from, type: presence.presenceType, context: context) {
            return
        }

        let bareJID = from.bareJID
        let resource: String = switch from {
        case let .full(fullJID): fullJID.resourcePart
        case .bare: ""
        }

        state.withLock { state in
            if presence.presenceType == .unavailable {
                state.presences[bareJID]?.removeValue(forKey: resource)
                if state.presences[bareJID]?.isEmpty == true {
                    state.presences.removeValue(forKey: bareJID)
                }
            } else if presence.presenceType == nil {
                // nil type means available
                state.presences[bareJID, default: [:]][resource] = presence
            }
        }

        // XEP-0153: Check for vcard-temp:x:update element
        if let vcardUpdate = presence.element.child(named: "x", namespace: XMPPNamespaces.vcardAvatarUpdate),
           presence.presenceType == nil {
            // Only process if <photo> child is present
            // Missing <photo> means "not ready to advertise" — skip
            if vcardUpdate.child(named: "photo") != nil {
                let hash = vcardUpdate.childText(named: "photo")
                let photoHash = (hash?.isEmpty == true) ? nil : hash
                context?.emitEvent(.vcardAvatarHashReceived(from: bareJID, hash: photoHash))
            }
        }

        context?.emitEvent(.presenceUpdated(from: from, presence: presence))
    }

    // MARK: - Public API

    /// Sets the own avatar hash for inclusion in outgoing presence broadcasts (XEP-0153). `nil` advertises
    /// that there is no avatar; until the first call, presence advertises neither.
    public func setOwnAvatarHash(_ hash: String?) {
        state.withLock { $0.ownAvatar = .known(hash: hash) }
    }

    /// Returns all known presences for a bare JID (one per resource).
    public func presences(for bareJID: BareJID) -> [XMPPPresence] {
        state.withLock { state in
            guard let resources = state.presences[bareJID] else { return [] }
            return Array(resources.values)
        }
    }

    /// Broadcasts a presence update to all contacts.
    public func broadcastPresence(show: XMPPPresence.Show? = nil, status: String? = nil, priority: Int? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var presence = XMPPPresence()
        presence.show = show
        presence.status = status
        if let priority { presence.priority = priority }
        appendAvatarHash(to: &presence)
        try await context.sendStanza(presence)
    }

    /// Sends a directed presence to a specific JID.
    public func sendDirectedPresence(to jid: JID, show: XMPPPresence.Show? = nil, status: String? = nil, priority: Int? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var presence = XMPPPresence(to: jid)
        presence.show = show
        presence.status = status
        if let priority { presence.priority = priority }
        appendAvatarHash(to: &presence)
        try await context.sendStanza(presence)
    }

    /// Handles subscription-related presence types. Returns `true` if the presence was handled.
    @discardableResult
    private func handleSubscriptionPresence(from: JID, type: XMPPPresence.PresenceType?, context: ModuleContext?) -> Bool? {
        switch type {
        case .subscribe:
            log.info("Subscription request from \(from)")
            context?.emitEvent(.presenceSubscriptionRequest(from: from.bareJID))
            return true
        case .subscribed:
            log.info("Subscription approved by \(from)")
            context?.emitEvent(.presenceSubscriptionApproved(from: from.bareJID))
            return true
        case .unsubscribed:
            log.info("Subscription revoked by \(from)")
            context?.emitEvent(.presenceSubscriptionRevoked(from: from.bareJID))
            return true
        case .unsubscribe, .probe, .error:
            // Server handles unsubscribe/probe; no client event needed
            return true
        case .unavailable, nil:
            return nil
        }
    }

    private func appendAvatarHash(to presence: inout XMPPPresence) {
        var x = XMLElement(name: "x", namespace: XMPPNamespaces.vcardAvatarUpdate)
        switch state.withLock({ $0.ownAvatar }) {
        case .notReady:
            break
        case let .known(hash):
            var photo = XMLElement(name: "photo")
            if let hash {
                photo.addText(hash)
            }
            x.addChild(photo)
        }
        presence.element.addChild(x)
    }
}
