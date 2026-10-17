import DuckoCore
import DuckoXMPP
import Foundation

extension ContactRecord {
    func toDomain() -> Contact? {
        guard let bareJID = BareJID.parse(jid), let accountID = account?.id else { return nil }
        return Contact(
            id: id,
            accountID: accountID,
            jid: bareJID,
            name: name,
            localAlias: localAlias,
            subscription: Contact.Subscription(rawValue: subscription) ?? .none,
            ask: ask,
            groups: groups,
            avatarHash: avatarHash,
            avatarData: avatarData,
            isBlocked: isBlocked,
            lastSeen: lastSeen,
            createdAt: createdAt
        )
    }

    func update(from contact: Contact) {
        jid = contact.jid.description
        name = contact.name
        localAlias = contact.localAlias
        subscription = contact.subscription.rawValue
        ask = contact.ask
        groups = contact.groups
        avatarHash = contact.avatarHash
        avatarData = contact.avatarData
        isBlocked = contact.isBlocked
        lastSeen = contact.lastSeen
    }
}
