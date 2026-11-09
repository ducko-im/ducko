import DuckoXMPP
import Foundation

/// The disco#info answers the modules of the account's client hold, read at use rather than copied from events, which
/// reach DuckoCore in no fixed order. Nil means the features are unknown.
@MainActor
package protocol DiscoveredFeatureSource {
    /// The account's disco#info, awaiting its query when it has not answered yet.
    func accountInfo(accountID: UUID) async -> ServiceDiscoveryModule.InfoResult?
    /// The room's disco#info: the stored answer, or else the room's own, asked for now.
    func roomInfo(_ room: BareJID, accountID: UUID) async -> ServiceDiscoveryModule.InfoResult?
    func knownAccountInfo(accountID: UUID) -> ServiceDiscoveryModule.InfoResult?
    func knownRoomInfo(_ room: BareJID, accountID: UUID) -> ServiceDiscoveryModule.InfoResult?
}

/// Reads the features from the modules of the account's attached client, connected or not yet, so the stanzas a resumed
/// stream replays before it counts as connected are judged by the features the resume carried.
struct ClientFeatureSource: DiscoveredFeatureSource {
    /// How long an archive read waits for a room's disco#info that is not stored yet.
    static let roomInfoTimeout: Duration = .seconds(5)

    let accountService: () -> AccountService?

    func accountInfo(accountID: UUID) async -> ServiceDiscoveryModule.InfoResult? {
        await accountService()?.discoveryModule(for: accountID)?.accountInfo()
    }

    func roomInfo(_ room: BareJID, accountID: UUID) async -> ServiceDiscoveryModule.InfoResult? {
        await accountService()?.roomModule(for: accountID)?.roomInfo(for: room, timeout: Self.roomInfoTimeout)
    }

    func knownAccountInfo(accountID: UUID) -> ServiceDiscoveryModule.InfoResult? {
        accountService()?.discoveryModule(for: accountID)?.knownAccountInfo
    }

    func knownRoomInfo(_ room: BareJID, accountID: UUID) -> ServiceDiscoveryModule.InfoResult? {
        accountService()?.roomModule(for: accountID)?.knownRoomInfo(for: room)
    }
}
