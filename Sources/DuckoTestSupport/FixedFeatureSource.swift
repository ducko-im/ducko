import DuckoCore
import DuckoXMPP
import Foundation

/// A feature source with fixed answers, for tests that run without a client to discover them. Nil features mean unknown.
public struct FixedFeatureSource: DiscoveredFeatureSource {
    public var accountFeatures: Set<String>?
    /// The features every room advertises.
    public var roomFeatures: Set<String>?

    public init(accountFeatures: Set<String>? = nil, roomFeatures: Set<String>? = nil) {
        self.accountFeatures = accountFeatures
        self.roomFeatures = roomFeatures
    }

    /// An account and rooms whose archives are read and whose stanza-ids are trusted: each lists `urn:xmpp:sid:0` and
    /// `urn:xmpp:mam:2`, and every room also lists `roomFeatures`.
    public static func archiving(roomFeatures: Set<String> = []) -> FixedFeatureSource {
        let archiveFeatures: Set<String> = [XMPPNamespaces.stanzaID, XMPPNamespaces.mam]
        return FixedFeatureSource(accountFeatures: archiveFeatures, roomFeatures: archiveFeatures.union(roomFeatures))
    }

    public func accountInfo(accountID: UUID) async -> ServiceDiscoveryModule.InfoResult? {
        knownAccountInfo(accountID: accountID)
    }

    public func roomInfo(_ room: BareJID, accountID: UUID) async -> ServiceDiscoveryModule.InfoResult? {
        knownRoomInfo(room, accountID: accountID)
    }

    public func knownAccountInfo(accountID: UUID) -> ServiceDiscoveryModule.InfoResult? {
        accountFeatures.map { ServiceDiscoveryModule.InfoResult(identities: [], features: $0) }
    }

    public func knownRoomInfo(_ room: BareJID, accountID: UUID) -> ServiceDiscoveryModule.InfoResult? {
        roomFeatures.map { ServiceDiscoveryModule.InfoResult(identities: [], features: $0) }
    }
}
