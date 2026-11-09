import DuckoXMPP
import Foundation

extension ChatService {
    /// The account, as the authority a stanza-id must name to be trusted, only when its known disco#info lists
    /// `urn:xmpp:sid:0`. Nil when it does not, or its features or address are unknown.
    func accountStanzaIDAuthority(accountID: UUID) -> BareJID? {
        guard let account = resolvedAccountJID(for: accountID) else { return nil }
        return Self.stanzaIDAuthority(account, info: featureSource.knownAccountInfo(accountID: accountID))
    }

    /// `room`, as the authority a stanza-id must name to be trusted, only when its known disco#info lists
    /// `urn:xmpp:sid:0`. Nil when it does not, or its features are unknown.
    func roomStanzaIDAuthority(_ room: BareJID, accountID: UUID) -> BareJID? {
        Self.stanzaIDAuthority(room, info: featureSource.knownRoomInfo(room, accountID: accountID))
    }

    private static func stanzaIDAuthority(_ entity: BareJID, info: ServiceDiscoveryModule.InfoResult?) -> BareJID? {
        info?.supportsStanzaIDs == true ? entity : nil
    }

    /// Whether `room`'s known disco#info lists `feature`. False when the room's features are unknown.
    func roomAdvertises(_ feature: String, room: BareJID, accountID: UUID) -> Bool {
        featureSource.knownRoomInfo(room, accountID: accountID)?.features.contains(feature) == true
    }
}
