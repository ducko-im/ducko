import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.avatar")

/// Avatar fetch result containing image data, hash, and MIME type.
public struct AvatarData: Sendable {
    public let data: Data
    public let hash: String
    public let mimeType: String

    public init(data: Data, hash: String, mimeType: String) {
        self.data = data
        self.hash = hash
        self.mimeType = mimeType
    }
}

@MainActor @Observable
public final class AvatarService {
    /// Per-account: whether each account's server supports XEP-0398 PEP-to-vCard conversion. Keyed by account
    /// so capabilities stay isolated across a multi-account session.
    private var serverSupportsConversionByAccount: [UUID: Bool] = [:]
    /// Per-account own avatar hash, used for presence broadcasts.
    private var ownAvatarHashByAccount: [UUID: String] = [:]

    private weak var accountService: AccountService?
    private weak var rosterService: RosterService?
    private weak var presenceService: PresenceService?
    private let store: any PersistenceStore

    public init(store: any PersistenceStore) {
        self.store = store
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setRosterService(_ service: RosterService) {
        rosterService = service
    }

    func setPresenceService(_ service: PresenceService) {
        presenceService = service
    }

    // MARK: - Lifecycle

    /// The account's own avatar hash, or nil when none is published/loaded for it.
    public func ownAvatarHash(for accountID: UUID) -> String? {
        ownAvatarHashByAccount[accountID]
    }

    /// Drops one account's avatar capability/hash on a lifecycle teardown that bypasses the `.disconnected`
    /// event handler (user-initiated `AccountService.disconnect`, account delete).
    func purgeAccount(_ accountID: UUID) {
        clearAvatarState(for: accountID)
    }

    private func clearAvatarState(for accountID: UUID) {
        serverSupportsConversionByAccount.removeValue(forKey: accountID)
        ownAvatarHashByAccount.removeValue(forKey: accountID)
    }

    private func serverSupportsConversion(for accountID: UUID) -> Bool {
        serverSupportsConversionByAccount[accountID] ?? false
    }

    /// True when the roster content generation for `accountID` is unchanged since `captured` (nil → no roster
    /// service wired, so there is nothing to republish). Peer-avatar handlers capture the generation before
    /// their first await and re-check before each contact write and reload, so a disconnect/purge during the
    /// fetch can't republish a just-cleared account via `RosterService.loadContacts` (which captures its own
    /// fresh generation).
    private func rosterGenerationUnchanged(_ captured: UInt64?, accountID: UUID) -> Bool {
        guard let captured else { return true }
        return rosterService?.contentGeneration(for: accountID) == captured
    }

    #if DEBUG
        /// Test seam: seeds per-account avatar state without a live connection, so per-account isolation and
        /// teardown can be exercised in unit tests.
        func setOwnAvatarHashForTesting(_ hash: String?, accountID: UUID) {
            ownAvatarHashByAccount[accountID] = hash
        }
    #endif

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        // A resumed stream runs on a new client, whose presence module does not know the own avatar yet.
        case .connected, .streamResumed:
            await handleConnected(accountID: accountID)
        case let .pepItemsPublished(from, node, items)
            where node == XMPPNamespaces.avatarMetadata:
            await handleAvatarMetadataPublished(from: from, items: items, accountID: accountID)
        case let .vcardAvatarHashReceived(from, hash):
            await handleVCardAvatarHash(from: from, hash: hash, accountID: accountID)
        case .disconnected:
            clearAvatarState(for: accountID)
        case .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterUpdated,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced, .omemoRecipientsPartial,
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    public enum AvatarServiceError: Error, LocalizedError {
        case notConnected(UUID)

        public var errorDescription: String? {
            switch self {
            case .notConnected: notConnectedDescription
            }
        }
    }

    // MARK: - Public API

    /// Publishes the user's avatar via XEP-0084 PEP and optionally XEP-0153 vCard.
    public func publishAvatar(imageData: Data, mimeType: String, accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw AvatarServiceError.notConnected(accountID) }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        let hash = sha1Hex(Array(imageData))
        let base64String = imageData.base64EncodedString()

        var dataPayload = DuckoXMPP.XMLElement(name: "data", namespace: XMPPNamespaces.avatarData)
        dataPayload.addText(base64String)
        try await pepModule.publishItem(
            node: XMPPNamespaces.avatarData,
            itemID: hash,
            payload: dataPayload
        )

        let metadata = buildMetadataElement(hash: hash, mimeType: mimeType, bytes: imageData.count)
        try await pepModule.publishItem(
            node: XMPPNamespaces.avatarMetadata,
            itemID: hash,
            payload: metadata
        )

        // Update vCard photo if server doesn't do conversion
        if !serverSupportsConversion(for: accountID) {
            await updateVCardPhoto(client: client, bytes: Array(imageData), mimeType: mimeType, accountID: accountID)
        }

        // A disconnect/purge during the publish tore the account down; don't restore its cleared hash.
        guard accountService?.connectedClient(for: accountID) === client else { return }
        ownAvatarHashByAccount[accountID] = hash
        presenceModule.setOwnAvatarHash(hash)
        await presenceService?.resendEffectivePresence(accountID: accountID)
        await resendPresenceToMUCRooms(client: client, presenceModule: presenceModule, accountID: accountID)
    }

    public func removeAvatar(accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw AvatarServiceError.notConnected(accountID) }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        let metadata = DuckoXMPP.XMLElement(name: "metadata", namespace: XMPPNamespaces.avatarMetadata)
        try await pepModule.publishItem(
            node: XMPPNamespaces.avatarMetadata,
            itemID: "current",
            payload: metadata
        )

        if !serverSupportsConversion(for: accountID) {
            await clearVCardPhoto(client: client, accountID: accountID)
        }

        // A disconnect/purge during the removal tore the account down; leave the purged state alone.
        guard accountService?.connectedClient(for: accountID) === client else { return }
        ownAvatarHashByAccount.removeValue(forKey: accountID)
        presenceModule.setOwnAvatarHash(nil)
        await presenceService?.resendEffectivePresence(accountID: accountID)
        await resendPresenceToMUCRooms(client: client, presenceModule: presenceModule, accountID: accountID)
    }

    public func fetchAvatar(for jid: BareJID, accountID: UUID) async -> AvatarData? {
        if let result = await fetchPEPAvatar(for: jid, accountID: accountID) {
            return result
        }
        return await fetchVCardAvatar(for: jid, accountID: accountID)
    }

    // MARK: - Private: MUC Presence

    /// XEP-0398 §4: Re-send directed presence to joined MUC rooms
    /// so room occupants receive the updated vcard-temp:x:update hash.
    private func resendPresenceToMUCRooms(client: XMPPClient, presenceModule: PresenceModule, accountID: UUID) async {
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        let show = presenceService?.effectiveShow(for: accountID)
        let status = presenceService?.effectivePresence(for: accountID).message
        for roomJID in mucModule.joinedRoomFullJIDs {
            try? await presenceModule.sendDirectedPresence(to: roomJID, show: show, status: status)
        }
    }

    // MARK: - Private: Connect

    private func handleConnected(accountID: UUID) async {
        // Wait until initial presence + caps are on the wire before any PEP/vCard fetch so the server has
        // seen this resource's caps first (XEP-0163 §3.3.2); the vCard hash fetch re-broadcasts presence.
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        await client.awaitInitialPresenceSent()

        async let conversionResult: Void = detectConversionSupport(accountID: accountID)
        async let hashResult: Void = loadOwnAvatarHash(accountID: accountID)
        _ = await (try? conversionResult, try? hashResult)
    }

    private func detectConversionSupport(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        guard let discoModule = await client.module(ofType: ServiceDiscoveryModule.self) else { return }
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }) else { return }

        do {
            let info = try await discoModule.queryInfo(for: .bare(account.jid))
            let supportsConversion = info.features.contains(XMPPNamespaces.pepVCardConversion)
            // A disconnect/purge during the await tore the account down; don't restore its cleared state.
            guard accountService?.connectedClient(for: accountID) === client else { return }
            serverSupportsConversionByAccount[accountID] = supportsConversion
            if supportsConversion {
                log.info("Server supports XEP-0398 PEP-vCard conversion")
            }
        } catch {
            log.warning("Failed to query server features: \(error.localizedDescription)")
        }
    }

    private func loadOwnAvatarHash(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        do {
            let vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true)
            // A disconnect/purge during the await tore the account down; don't restore its cleared state.
            guard accountService?.connectedClient(for: accountID) === client else { return }
            ownAvatarHashByAccount[accountID] = vcard?.photoHash
            presenceModule.setOwnAvatarHash(vcard?.photoHash)
            // Re-broadcast presence so contacts receive the XEP-0153 hash
            // (initial presence was sent before this fetch completed)
            await presenceService?.resendEffectivePresence(accountID: accountID)
        } catch {
            log.warning("Failed to fetch own vCard for avatar hash: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: PEP Avatar Metadata

    private func handleAvatarMetadataPublished(from: BareJID, items: [PEPItem], accountID: UUID) async {
        let rosterGeneration = rosterService?.contentGeneration(for: accountID)
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }),
              from != account.jid else { return }

        guard let item = items.first else { return }
        let metadata = item.payload

        guard let info = metadata.child(named: "info") else {
            guard let contact = await findContact(jid: from, accountID: accountID) else { return }
            await clearContactAvatar(contact, accountID: accountID, rosterGeneration: rosterGeneration)
            return
        }

        // XEP-0084 requires the <info> id (the image's SHA-1). Without it there is no stable hash to compare or
        // record, so a peer publishing id-less metadata would otherwise force a fetch on every notification.
        // Treat it as malformed and ignore it, consistent with the record-hash-then-suppress model.
        guard let hash = info.attribute("id"), !hash.isEmpty else {
            log.warning("Ignoring PEP avatar metadata without the required info id")
            return
        }
        guard let contact = await findContact(jid: from, accountID: accountID) else { return }

        if contact.avatarHash == hash { return }

        await fetchAndStoreAvatar(for: contact, hash: hash, accountID: accountID, rosterGeneration: rosterGeneration)
    }

    // MARK: - Private: vCard Avatar Hash

    private func handleVCardAvatarHash(from: BareJID, hash: String?, accountID: UUID) async {
        let rosterGeneration = rosterService?.contentGeneration(for: accountID)
        guard let contact = await findContact(jid: from, accountID: accountID) else { return }

        guard let hash else {
            if contact.avatarHash != nil {
                await clearContactAvatar(contact, accountID: accountID, rosterGeneration: rosterGeneration)
            }
            return
        }

        if contact.avatarHash == hash { return }

        guard let client = accountService?.connectedClient(for: accountID) else { return }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return }

        do {
            let vcard = try await vcardModule.fetchVCard(for: from, forceRefresh: true)
            guard let photoData = vcard?.photoData else { return }
            // Record the hash without the image (data == nil) for an oversized photo, so the same one isn't
            // re-fetched on every subsequent notification carrying it.
            let data: Data? = photoData.count <= AvatarLimits.maxBytes ? Data(photoData) : nil
            if data == nil { log.warning("Dropping oversized avatar (\(photoData.count) bytes)") }
            await storeContactAvatar(data, hash: hash, for: contact, accountID: accountID, rosterGeneration: rosterGeneration)
        } catch {
            log.warning("Failed to fetch vCard avatar for \(from): \(error.localizedDescription)")
        }
    }

    private func fetchAndStoreAvatar(for contact: Contact, hash: String?, accountID: UUID, rosterGeneration: UInt64?) async {
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return }

        do {
            let items = try await pepModule.retrieveItems(
                node: XMPPNamespaces.avatarData,
                from: contact.jid,
                maxItems: 1
            )
            guard let item = items.first, let base64Text = item.payload.textContent else { return }

            // Pre-check the encoded length (base64 expands ~4/3) before decoding; nil data (oversized or
            // undecodable) records only the hash so the payload isn't re-fetched on every notification.
            let data: Data? = base64Text.utf8.count <= AvatarLimits.maxBytes / 3 * 4 + 4
                ? Data(base64Encoded: base64Text, options: .ignoreUnknownCharacters).flatMap { $0.count <= AvatarLimits.maxBytes ? $0 : nil }
                : nil
            await storeContactAvatar(data, hash: hash, for: contact, accountID: accountID, rosterGeneration: rosterGeneration)
        } catch {
            log.warning("Failed to fetch PEP avatar data for \(contact.jid): \(error.localizedDescription)")
        }
    }

    /// Writes a peer's fetched avatar to its contact and republishes the roster, guarded by the roster
    /// `rosterGeneration` captured before the fetch so a disconnect/purge during the await can't resurrect a
    /// torn-down account. `data == nil` (oversized/undecodable payloads) records the new hash and clears any
    /// previously stored bytes — keeping the stale image would pin it, since the recorded hash suppresses
    /// re-fetches. The roster reload runs only when visible avatar state actually changed; a nil `hash` with nil
    /// `data` is a no-op.
    private func storeContactAvatar(_ data: Data?, hash: String?, for contact: Contact, accountID: UUID, rosterGeneration: UInt64?) async {
        guard rosterGenerationUnchanged(rosterGeneration, accountID: accountID) else { return }
        let update: ContactMetadataUpdate
        let shouldReload: Bool
        if let data {
            update = .avatar(hash: hash ?? sha1Hex(Array(data)), data: data)
            shouldReload = true
        } else if let hash {
            update = .avatar(hash: hash, data: nil)
            shouldReload = contact.avatarData != nil
        } else {
            return
        }
        try? await store.updateContactIfExists(contact.id, accountID: accountID, update: update)
        guard shouldReload else { return }
        try? await rosterService?.loadContacts(for: accountID, ifGenerationUnchangedSince: rosterGeneration ?? 0)
    }

    private func fetchPEPAvatar(for jid: BareJID, accountID: UUID) async -> AvatarData? {
        guard let client = accountService?.connectedClient(for: accountID) else { return nil }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return nil }

        do {
            let metaItems = try await pepModule.retrieveItems(
                node: XMPPNamespaces.avatarMetadata,
                from: jid,
                maxItems: 1
            )
            guard let metaItem = metaItems.first,
                  let info = metaItem.payload.child(named: "info") else { return nil }

            // XEP-0084 requires the <info> id (the image SHA-1). Treat missing/empty as malformed and fall back to
            // vCard rather than returning an avatar under an invalid cache key, matching the notification path.
            guard let hash = info.attribute("id"), !hash.isEmpty else { return nil }
            let mimeType = info.attribute("type") ?? "image/png"

            let dataItems = try await pepModule.retrieveItems(
                node: XMPPNamespaces.avatarData,
                from: jid,
                maxItems: 1
            )
            guard let dataItem = dataItems.first,
                  let base64Text = dataItem.payload.textContent,
                  // Pre-check the encoded length (base64 expands ~4/3) before decoding.
                  base64Text.utf8.count <= AvatarLimits.maxBytes / 3 * 4 + 4,
                  let data = Data(base64Encoded: base64Text, options: .ignoreUnknownCharacters),
                  data.count <= AvatarLimits.maxBytes
            else { return nil }

            return AvatarData(data: data, hash: hash, mimeType: mimeType)
        } catch {
            return nil
        }
    }

    private func fetchVCardAvatar(for jid: BareJID, accountID: UUID) async -> AvatarData? {
        guard let client = accountService?.connectedClient(for: accountID) else { return nil }
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return nil }

        do {
            let vcard = try await vcardModule.fetchVCard(for: jid, forceRefresh: true)
            guard let photoData = vcard?.photoData, photoData.count <= AvatarLimits.maxBytes else { return nil }
            let hash = vcard?.photoHash ?? sha1Hex(photoData)
            let mimeType = vcard?.photoType ?? "image/png"
            return AvatarData(data: Data(photoData), hash: hash, mimeType: mimeType)
        } catch {
            return nil
        }
    }

    private func clearContactAvatar(_ contact: Contact, accountID: UUID, rosterGeneration: UInt64?) async {
        // A disconnect/purge during the fetch tore the account down; don't write its contact or republish.
        guard rosterGenerationUnchanged(rosterGeneration, accountID: accountID) else { return }
        try? await store.updateContactIfExists(contact.id, accountID: accountID, update: .avatar(hash: nil, data: nil))
        try? await rosterService?.loadContacts(for: accountID, ifGenerationUnchangedSince: rosterGeneration ?? 0)
    }

    private func updateVCardPhoto(client: XMPPClient, bytes: [UInt8], mimeType: String, accountID: UUID) async {
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return }

        do {
            var vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true) ?? VCardModule.VCard()
            // A disconnect/purge during the fetch tore the account down; don't publish a stale vCard.
            guard accountService?.connectedClient(for: accountID) === client else { return }
            vcard.photoData = bytes
            vcard.photoType = mimeType
            vcard.photoHash = sha1Hex(bytes)
            try await vcardModule.publishVCard(vcard)
        } catch {
            log.warning("Failed to update vCard photo: \(error.localizedDescription)")
        }
    }

    private func clearVCardPhoto(client: XMPPClient, accountID: UUID) async {
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return }

        do {
            var vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true) ?? VCardModule.VCard()
            // A disconnect/purge during the fetch tore the account down; don't publish a stale vCard.
            guard accountService?.connectedClient(for: accountID) === client else { return }
            vcard.photoData = nil
            vcard.photoType = nil
            vcard.photoHash = nil
            try await vcardModule.publishVCard(vcard)
        } catch {
            log.warning("Failed to clear vCard photo: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Metadata XML

    private func buildMetadataElement(hash: String, mimeType: String, bytes: Int) -> DuckoXMPP.XMLElement {
        var metadata = DuckoXMPP.XMLElement(name: "metadata", namespace: XMPPNamespaces.avatarMetadata)
        let info = DuckoXMPP.XMLElement(name: "info", attributes: [
            "id": hash,
            "type": mimeType,
            "bytes": "\(bytes)"
        ])
        metadata.addChild(info)
        return metadata
    }

    // MARK: - Private: Contact Lookup

    private func findContact(jid: BareJID, accountID: UUID) async -> Contact? {
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        return contacts.first(where: { $0.jid == jid })
    }
}
