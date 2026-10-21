import DuckoCore
import DuckoXMPP

extension AccountRecord {
    func toDomain() -> Account? {
        guard let bareJID = BareJID.parse(jid) else { return nil }
        return Account(
            id: id,
            jid: bareJID,
            displayName: displayName,
            isEnabled: isEnabled,
            connectOnLaunch: connectOnLaunch,
            host: host,
            port: port,
            resource: resource,
            requireTLS: requireTLS,
            rosterVersion: rosterVersion,
            certificateFingerprint: certificateFingerprint,
            requiresSCRAM: requiresSCRAM,
            importedFrom: importedFrom,
            createdAt: createdAt
        )
    }

    func update(from account: Account) {
        jid = account.jid.description
        displayName = account.displayName
        isEnabled = account.isEnabled
        connectOnLaunch = account.connectOnLaunch
        host = account.host
        port = account.port
        resource = account.resource
        requireTLS = account.requireTLS
        certificateFingerprint = account.certificateFingerprint
        importedFrom = account.importedFrom
    }
}
