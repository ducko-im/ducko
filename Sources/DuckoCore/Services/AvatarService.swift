import DuckoXMPP
import Foundation
import ImageIO
import Logging
import UniformTypeIdentifiers

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
    /// Per-account `<info>` id of the avatar metadata this device last published (nil for a removal), until the
    /// notification of that publish arrives, so it is not taken for a change made on another device.
    private var publishedAvatarIDByAccount: [UUID: String?] = [:]
    /// Accounts whose presence module withholds the own avatar hash, as last seen, so the moment the last resource
    /// without vCard avatar support goes offline is noticed.
    private var accountsWithheldAvatar: Set<UUID> = []

    private weak var accountService: AccountService?
    private weak var rosterService: RosterService?
    private weak var presenceService: PresenceService?
    private weak var profileService: ProfileService?
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

    func setProfileService(_ service: ProfileService) {
        profileService = service
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
        publishedAvatarIDByAccount.removeValue(forKey: accountID)
        accountsWithheldAvatar.remove(accountID)
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
        case let .presenceUpdated(from, _):
            await handleOwnResourcePresence(from: from, accountID: accountID)
        case .disconnected:
            clearAvatarState(for: accountID)
        case .authenticationFailed, .plainSignInRefused,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterUpdated,
             .presenceSubscriptionRequest,
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
             .oobIQOfferReceived:
            break
        }
    }

    public enum AvatarServiceError: Error, LocalizedError {
        case notConnected(UUID)
        case pictureTooLarge
        case notAPicture
        case avatarsUnsupported
        case pictureNotRemoved

        public var errorDescription: String? {
            switch self {
            case .notConnected: notConnectedDescription
            case .pictureTooLarge:
                "The picture is larger than \(ByteCountFormatter.string(fromByteCount: Int64(AvatarLimits.maxPictureFileBytes), countStyle: .memory))"
            case .notAPicture: "The file is not a picture that can be read"
            case .avatarsUnsupported: "The server cannot share avatars, so the picture was not published"
            case .pictureNotRemoved: "The server kept the picture in your profile, so contacts can still see it"
            }
        }
    }

    // MARK: - Public API

    /// Publishes the user's avatar as PNG via XEP-0084 PEP and optionally XEP-0153 vCard, and returns the published
    /// picture.
    @discardableResult
    public func publishAvatar(imageData: Data, accountID: UUID) async throws -> AvatarData {
        guard imageData.count <= AvatarLimits.maxPictureFileBytes else { throw AvatarServiceError.pictureTooLarge }
        // Contacts show an avatar only once it decodes. Scaled down, the PNG stays far below the cap they drop one over.
        guard let png = PNGEncoder.encode(imageData) else { throw AvatarServiceError.notAPicture }
        guard let client = accountService?.connectedClient(for: accountID), let pepModule = await client.module(ofType: PEPModule.self), let presenceModule = await client.module(ofType: PresenceModule.self), let discoModule = await client.module(ofType: ServiceDiscoveryModule.self), let account = accountService?.accounts.first(where: { $0.id == accountID }) else {
            throw AvatarServiceError.notConnected(accountID)
        }
        guard try await discoModule.queryInfo(for: .bare(account.jid)).supportsPEPPublishing else {
            throw AvatarServiceError.avatarsUnsupported
        }

        let avatar = AvatarData(data: png.data, hash: sha1Hex(Array(png.data)), mimeType: "image/png")
        let hash = avatar.hash
        let base64String = avatar.data.base64EncodedString()

        var dataPayload = DuckoXMPP.XMLElement(name: "data", namespace: XMPPNamespaces.avatarData)
        dataPayload.addText(base64String)
        try await pepModule.publishItem(
            node: XMPPNamespaces.avatarData,
            itemID: hash,
            payload: dataPayload
        )

        let metadata = buildMetadataElement(for: png, hash: hash)
        publishedAvatarIDByAccount[accountID] = hash
        try await pepModule.publishItem(
            node: XMPPNamespaces.avatarMetadata,
            itemID: hash,
            payload: metadata
        )

        // Contacts read the advertised picture from the vCard, so the hash is advertised only once the vCard holds it
        // (XEP-0153 §4.2). Either the server converts the PEP avatar, or the vCard is updated here.
        var vcardHoldsAvatar = serverSupportsConversion(for: accountID)
        if !vcardHoldsAvatar {
            vcardHoldsAvatar = await updateVCardPhoto(client: client, avatar: avatar, accountID: accountID)
        }

        // A disconnect/purge during the publish tore the account down; don't restore its cleared hash.
        guard vcardHoldsAvatar, accountService?.connectedClient(for: accountID) === client else { return avatar }
        ownAvatarHashByAccount[accountID] = hash
        presenceModule.setOwnAvatarHash(hash)
        await presenceService?.resendEffectivePresence(accountID: accountID)
        await resendPresenceToMUCRooms(client: client, presenceModule: presenceModule, accountID: accountID)
        return avatar
    }

    /// Removes the user's avatar from PEP where the server supports it (XEP-0084 §3.5), and from the vCard unless the
    /// server converts PEP avatars into it.
    public func removeAvatar(accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID), let account = accountService?.accounts.first(where: { $0.id == accountID }) else {
            throw AvatarServiceError.notConnected(accountID)
        }
        guard let pepModule = await client.module(ofType: PEPModule.self), let presenceModule = await client.module(ofType: PresenceModule.self), let discoModule = await client.module(ofType: ServiceDiscoveryModule.self) else { return }

        if try await discoModule.queryInfo(for: .bare(account.jid)).supportsPEPPublishing {
            let metadata = DuckoXMPP.XMLElement(name: "metadata", namespace: XMPPNamespaces.avatarMetadata)
            publishedAvatarIDByAccount[accountID] = .some(nil)
            try await pepModule.publishItem(
                node: XMPPNamespaces.avatarMetadata,
                itemID: "current",
                payload: metadata
            )
        }

        // Contacts read the advertised picture from the vCard, so no avatar is advertised until the vCard drops it.
        var vcardDropsAvatar = serverSupportsConversion(for: accountID)
        if !vcardDropsAvatar {
            vcardDropsAvatar = await clearVCardPhoto(client: client, accountID: accountID)
        }

        // A disconnect/purge during the removal tore the account down; leave the purged state alone.
        guard accountService?.connectedClient(for: accountID) === client else { return }
        guard vcardDropsAvatar else { throw AvatarServiceError.pictureNotRemoved }
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
        async let vcardResult: Void = loadOwnVCard(accountID: accountID)
        _ = await (try? conversionResult, try? vcardResult)
    }

    private func detectConversionSupport(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID), let discoModule = await client.module(ofType: ServiceDiscoveryModule.self), let account = accountService?.accounts.first(where: { $0.id == accountID }) else { return }

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

    private func loadOwnVCard(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID), let vcardModule = await client.module(ofType: VCardModule.self), let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        do {
            let vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true)
            // A disconnect/purge during the await tore the account down; don't restore its cleared state.
            guard accountService?.connectedClient(for: accountID) === client else { return }
            ownAvatarHashByAccount[accountID] = vcard?.photoHash
            profileService?.receiveOwnVCard(vcard, accountID: accountID)
            presenceModule.setOwnAvatarHash(vcard?.photoHash)
            // Re-broadcast presence so contacts and rooms receive the XEP-0153 hash
            // (initial presence and room joins went out before this fetch completed)
            await presenceService?.resendEffectivePresence(accountID: accountID)
            await resendPresenceToMUCRooms(client: client, presenceModule: presenceModule, accountID: accountID)
        } catch {
            log.warning("Failed to fetch own vCard: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: The Account's Other Devices

    /// Whether `jid` is another resource of the account, not the one this session is bound to.
    private func isOtherOwnResource(_ jid: JID, accountID: UUID) -> Bool {
        guard case let .full(fullJID) = jid, case let .connected(boundJID)? = accountService?.connectionStates[accountID] else { return false }
        return fullJID.bareJID == boundJID.bareJID && fullJID != boundJID
    }

    /// Follows another resource's vCard avatar hash (XEP-0153 §4.3): an empty photo or a different hash means it changed
    /// the vCard, so the advertised hash is reset to the vCard's photo. This resource's own presence echo is ignored.
    private func followOwnResourceAvatarHash(_ hash: String?, from: JID, accountID: UUID) async {
        guard isOtherOwnResource(from, accountID: accountID), hash != ownAvatarHashByAccount[accountID] else { return }
        await resetOwnAvatarHash(accountID: accountID)
    }

    /// Resets the advertised hash (XEP-0153 §4.4): presence goes out without one at once, and the vCard read next
    /// supplies the hash advertised from then on.
    private func resetOwnAvatarHash(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID), let presenceModule = await client.module(ofType: PresenceModule.self) else { return }
        presenceModule.resetOwnAvatarHash()
        await presenceService?.resendEffectivePresence(accountID: accountID)
        await resendPresenceToMUCRooms(client: client, presenceModule: presenceModule, accountID: accountID)
        await loadOwnVCard(accountID: accountID)
    }

    /// Follows an avatar published or removed on another device. What this device advertises comes from the vCard
    /// (XEP-0153 §4.2), so a change re-reads it. The first notification naming what this device published is its own,
    /// and later ones are another device's.
    private func followOwnAvatarMetadata(id: String?, accountID: UUID) async {
        if publishedAvatarIDByAccount[accountID] == .some(id) {
            publishedAvatarIDByAccount.removeValue(forKey: accountID)
            return
        }
        guard id != ownAvatarHashByAccount[accountID] else { return }
        await loadOwnVCard(accountID: accountID)
    }

    /// Notices when the last resource without vCard avatar support goes offline or starts sending the update element.
    /// That resource could have changed the vCard unseen, so the hash is reset from the vCard before it is advertised
    /// again (XEP-0153 §4.3).
    private func handleOwnResourcePresence(from: JID, accountID: UUID) async {
        guard isOtherOwnResource(from, accountID: accountID), let client = accountService?.connectedClient(for: accountID), let presenceModule = await client.module(ofType: PresenceModule.self) else { return }
        if presenceModule.withholdsOwnAvatar {
            accountsWithheldAvatar.insert(accountID)
        } else if accountsWithheldAvatar.remove(accountID) != nil {
            await loadOwnVCard(accountID: accountID)
        }
    }

    // MARK: - Private: PEP Avatar Metadata

    private func handleAvatarMetadataPublished(from: BareJID, items: [PEPItem], accountID: UUID) async {
        let rosterGeneration = rosterService?.contentGeneration(for: accountID)
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }), let item = items.first else { return }
        let info = Self.pngInfo(in: item.payload)
        guard from != account.jid else {
            await followOwnAvatarMetadata(id: info?.attribute("id"), accountID: accountID)
            return
        }

        guard let info else {
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

    private func handleVCardAvatarHash(from: JID, hash: String?, accountID: UUID) async {
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }) else { return }
        guard from.bareJID != account.jid else {
            await followOwnResourceAvatarHash(hash, from: from, accountID: accountID)
            return
        }
        let rosterGeneration = rosterService?.contentGeneration(for: accountID)
        guard let contact = await findContact(jid: from.bareJID, accountID: accountID) else { return }

        guard let hash else {
            if contact.avatarHash != nil {
                await clearContactAvatar(contact, accountID: accountID, rosterGeneration: rosterGeneration)
            }
            return
        }

        if contact.avatarHash == hash { return }

        guard let client = accountService?.connectedClient(for: accountID), let vcardModule = await client.module(ofType: VCardModule.self) else { return }

        do {
            let vcard = try await vcardModule.fetchVCard(for: from.bareJID, forceRefresh: true)
            guard let photoData = vcard?.photoData else { return }
            // Record the hash without the image (data == nil) for an oversized photo, so the same one isn't
            // re-fetched on every subsequent notification carrying it.
            let data: Data? = photoData.count <= AvatarLimits.maxBytes ? Data(photoData) : nil
            if data == nil { log.warning("Dropping oversized avatar (\(photoData.count) bytes)") }
            await storeContactAvatar(data, hash: hash, for: contact, accountID: accountID, rosterGeneration: rosterGeneration)
        } catch {
            log.warning("Failed to fetch vCard avatar: \(error.localizedDescription)")
            log.debug("The failed vCard avatar fetch was for \(from)")
        }
    }

    private func fetchAndStoreAvatar(for contact: Contact, hash: String?, accountID: UUID, rosterGeneration: UInt64?) async {
        guard let client = accountService?.connectedClient(for: accountID), let pepModule = await client.module(ofType: PEPModule.self) else { return }

        do {
            let items = try await pepModule.retrieveItems(
                node: XMPPNamespaces.avatarData,
                from: contact.jid,
                itemID: hash
            )
            guard let item = items.first, let base64Text = item.payload.textContent else { return }

            // Pre-check the encoded length (base64 expands ~4/3) before decoding; nil data (oversized or
            // undecodable) records only the hash so the payload isn't re-fetched on every notification.
            let data: Data? = base64Text.utf8.count <= AvatarLimits.maxBytes / 3 * 4 + 4
                ? Data(base64Encoded: base64Text, options: .ignoreUnknownCharacters).flatMap { $0.count <= AvatarLimits.maxBytes ? $0 : nil }
                : nil
            await storeContactAvatar(data, hash: hash, for: contact, accountID: accountID, rosterGeneration: rosterGeneration)
        } catch {
            log.warning("Failed to fetch PEP avatar data: \(error.localizedDescription)")
            log.debug("The failed PEP avatar fetch was for \(contact.jid)")
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
        guard let client = accountService?.connectedClient(for: accountID), let pepModule = await client.module(ofType: PEPModule.self) else { return nil }

        do {
            let metaItems = try await pepModule.retrieveItems(
                node: XMPPNamespaces.avatarMetadata,
                from: jid,
                maxItems: 1
            )
            guard let metaItem = metaItems.first,
                  let info = Self.pngInfo(in: metaItem.payload) else { return nil }

            // XEP-0084 requires the <info> id (the image SHA-1). Treat missing/empty as malformed and fall back to
            // vCard rather than returning an avatar under an invalid cache key, matching the notification path.
            guard let hash = info.attribute("id"), !hash.isEmpty else { return nil }
            let mimeType = info.attribute("type") ?? "image/png"

            let dataItems = try await pepModule.retrieveItems(
                node: XMPPNamespaces.avatarData,
                from: jid,
                itemID: hash
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
        guard let client = accountService?.connectedClient(for: accountID), let vcardModule = await client.module(ofType: VCardModule.self) else { return nil }

        do {
            let vcard = try await vcardModule.fetchVCard(for: jid, forceRefresh: true)
            guard let photoData = vcard?.photoData, photoData.count <= AvatarLimits.maxBytes else { return nil }
            let hash = vcard?.photoHash ?? sha1Hex(photoData)
            // The vCard's TYPE is only a hint, which the data overrules (XEP-0153 §5).
            let data = Data(photoData)
            return AvatarData(data: data, hash: hash, mimeType: Self.imageMIMEType(of: data) ?? "image/png")
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

    /// Stores the picture in the own vCard, and returns whether it was stored.
    private func updateVCardPhoto(client: XMPPClient, avatar: AvatarData, accountID: UUID) async -> Bool {
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return false }

        do {
            var vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true) ?? VCardModule.VCard()
            // A disconnect/purge during the fetch tore the account down; don't publish a stale vCard.
            guard accountService?.connectedClient(for: accountID) === client else { return false }
            vcard.photoData = Array(avatar.data)
            vcard.photoType = avatar.mimeType
            vcard.photoHash = avatar.hash
            try await vcardModule.publishVCard(vcard)
            return true
        } catch {
            log.warning("Failed to update vCard photo: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes the picture from the own vCard, and returns whether it was removed.
    private func clearVCardPhoto(client: XMPPClient, accountID: UUID) async -> Bool {
        guard let vcardModule = await client.module(ofType: VCardModule.self) else { return false }

        do {
            var vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true) ?? VCardModule.VCard()
            // A disconnect/purge during the fetch tore the account down; don't publish a stale vCard.
            guard accountService?.connectedClient(for: accountID) === client else { return false }
            vcard.photoData = nil
            vcard.photoType = nil
            vcard.photoHash = nil
            try await vcardModule.publishVCard(vcard)
            return true
        } catch {
            log.warning("Failed to clear vCard photo: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private: Metadata XML

    private func buildMetadataElement(for png: PNGEncoder.Image, hash: String) -> DuckoXMPP.XMLElement {
        var metadata = DuckoXMPP.XMLElement(name: "metadata", namespace: XMPPNamespaces.avatarMetadata)
        let info = DuckoXMPP.XMLElement(name: "info", attributes: [
            "id": hash,
            "type": "image/png",
            "bytes": "\(png.data.count)",
            "width": "\(png.width)",
            "height": "\(png.height)"
        ])
        metadata.addChild(info)
        return metadata
    }

    /// The `<info>` of the PNG form, whose id names the item in the data node (XEP-0084 §3.1), or the first
    /// `<info>` when a publisher lists no PNG.
    private static func pngInfo(in metadata: DuckoXMPP.XMLElement) -> DuckoXMPP.XMLElement? {
        metadata.children(named: "info").first { $0.attribute("type") == "image/png" } ?? metadata.child(named: "info")
    }

    /// The MIME type of the picture in `data`, or nil when it is not a picture ImageIO can read.
    private static func imageMIMEType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else { return nil }
        return UTType(type as String)?.preferredMIMEType
    }

    // MARK: - Private: Contact Lookup

    private func findContact(jid: BareJID, accountID: UUID) async -> Contact? {
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        return contacts.first(where: { $0.jid == jid })
    }
}
