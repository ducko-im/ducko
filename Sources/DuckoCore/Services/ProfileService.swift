import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.profile")

@MainActor @Observable
public final class ProfileService {
    public enum ProfileServiceError: Error, LocalizedError {
        case notConnected(UUID)
        case invalidJID(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected: notConnectedDescription
            case let .invalidJID(string): "Invalid JID: \(string)"
            }
        }
    }

    private var ownProfilesByAccount: [UUID: ProfileInfo] = [:]

    /// The fetched/published profile for a specific account. Keyed by account so
    /// switching the active account never surfaces a previous account's profile.
    public func ownProfile(for accountID: UUID) -> ProfileInfo? {
        ownProfilesByAccount[accountID]
    }

    private weak var accountService: AccountService?

    public init() {}

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    // MARK: - Lifecycle

    /// Drops a deleted account's own profile. A disconnect keeps it, so your photo and nickname still show while you
    /// are offline.
    func forgetAccount(_ accountID: UUID) {
        ownProfilesByAccount.removeValue(forKey: accountID)
    }

    #if DEBUG
        /// Test seam: seeds a per-account own-profile without a live fetch, so per-account purge/isolation can
        /// be exercised in unit tests.
        func setOwnProfileForTesting(_ profile: ProfileInfo, accountID: UUID) {
            ownProfilesByAccount[accountID] = profile
        }
    #endif

    /// Takes the account's own vCard as fetched on connect. Having none clears the profile, so one removed meanwhile
    /// does not keep showing.
    func receiveOwnVCard(_ vcard: VCardModule.VCard?, accountID: UUID) {
        ownProfilesByAccount[accountID] = vcard.map { mapVCardToProfileInfo($0) }
    }

    // MARK: - Public API

    public func fetchOwnProfile(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID), let vcardModule = await client.module(ofType: VCardModule.self) else { return }

        do {
            let vcard = try await vcardModule.fetchOwnVCard(forceRefresh: true)
            // A disconnect during the await ended this connection, and a delete may have dropped the profile since.
            guard accountService?.connectedClient(for: accountID) === client else { return }
            if let vcard {
                ownProfilesByAccount[accountID] = mapVCardToProfileInfo(vcard)
            }
        } catch {
            log.warning("Failed to fetch own vCard: \(error)")
        }
    }

    /// Fetches a peer's vCard profile. Distinct from `fetchOwnProfile`, which targets the
    /// connected JID with no `to` attribute per XEP-0054; this addresses the peer's bare JID.
    public func fetchProfile(for jidString: String, accountID: UUID) async throws -> ProfileInfo {
        guard let jid = BareJID.parse(jidString) else {
            throw ProfileServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.connectedClient(for: accountID), let vcardModule = await client.module(ofType: VCardModule.self) else {
            throw ProfileServiceError.notConnected(accountID)
        }

        do {
            let vcard = try await vcardModule.fetchVCard(for: jid, forceRefresh: true)
            return vcard.map { mapVCardToProfileInfo($0) } ?? ProfileInfo()
        } catch let stanzaError as XMPPStanzaError where stanzaError.condition == .itemNotFound {
            // A peer that has never published a vCard is the common case — surface an
            // empty profile rather than an error.
            return ProfileInfo()
        }
    }

    public func publishProfile(_ profile: ProfileInfo, accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID), let vcardModule = await client.module(ofType: VCardModule.self) else {
            throw ProfileServiceError.notConnected(accountID)
        }

        var vcard = mapProfileInfoToVCard(profile)
        // Re-fetch the current raw vCard before each publish so unmodeled XML (custom X-* fields) survives
        // across successive publishes. "No vCard yet" — item-not-found, or nil when there's no connected
        // context — means there is nothing to preserve; any other fetch error fails the publish rather than
        // silently dropping unmodeled XML.
        do {
            if let fetched = try await vcardModule.fetchOwnVCard(forceRefresh: true) {
                vcard.rawElement = fetched.rawElement
            }
        } catch let stanzaError as XMPPStanzaError where stanzaError.condition == .itemNotFound {}
        try await vcardModule.publishVCard(vcard)
        // A disconnect during the publish ended this connection, and a delete may have dropped the profile since.
        guard accountService?.connectedClient(for: accountID) === client else { return }
        ownProfilesByAccount[accountID] = profile
    }

    // MARK: - Mapping

    private func mapVCardToProfileInfo(_ vcard: VCardModule.VCard) -> ProfileInfo {
        ProfileInfo(
            fullName: vcard.fullName,
            nickname: vcard.nickname,
            familyName: vcard.name?.familyName,
            givenName: vcard.name?.givenName,
            middleName: vcard.name?.middleName,
            namePrefix: vcard.name?.prefix,
            nameSuffix: vcard.name?.suffix,
            emails: vcard.emails.map { mapEmail($0) },
            telephones: vcard.telephones.map { mapTelephone($0) },
            addresses: vcard.addresses.map { mapAddress($0) },
            organization: vcard.organization,
            title: vcard.title,
            role: vcard.role,
            url: vcard.url,
            birthday: vcard.birthday,
            note: vcard.note,
            // Drop an oversized server-supplied photo rather than caching it, in
            // line with the contact-avatar ingestion cap.
            photoData: vcard.photoData.flatMap { $0.count <= AvatarLimits.maxBytes ? Data($0) : nil },
            photoType: vcard.photoType
        )
    }

    private func mapProfileInfoToVCard(_ profile: ProfileInfo) -> VCardModule.VCard {
        var name: VCardModule.VCard.Name?
        if profile.familyName != nil || profile.givenName != nil || profile.middleName != nil
            || profile.namePrefix != nil || profile.nameSuffix != nil {
            name = VCardModule.VCard.Name(
                familyName: profile.familyName,
                givenName: profile.givenName,
                middleName: profile.middleName,
                prefix: profile.namePrefix,
                suffix: profile.nameSuffix
            )
        }

        let photoBytes = profile.photoData.map { Array($0) }
        let photoHash: String? = photoBytes.map { sha1Hex($0) }

        return VCardModule.VCard(
            fullName: profile.fullName,
            nickname: profile.nickname,
            name: name,
            emails: profile.emails.map { mapEmailBack($0) },
            telephones: profile.telephones.map { mapTelephoneBack($0) },
            addresses: profile.addresses.map { mapAddressBack($0) },
            organization: profile.organization,
            title: profile.title,
            role: profile.role,
            url: profile.url,
            birthday: profile.birthday,
            note: profile.note,
            photoData: photoBytes,
            photoType: profile.photoType,
            photoHash: photoHash
        )
    }

    // MARK: - Entry Type Mapping

    private func mapEntryType(_ type: VCardModule.EntryType) -> ProfileInfo.EntryType {
        switch type {
        case .home: .home
        case .work: .work
        }
    }

    private func mapEntryTypeBack(_ type: ProfileInfo.EntryType) -> VCardModule.EntryType {
        switch type {
        case .home: .home
        case .work: .work
        }
    }

    private func mapEmail(_ email: VCardModule.VCard.Email) -> ProfileInfo.EmailEntry {
        ProfileInfo.EmailEntry(address: email.address, types: email.types.map { mapEntryType($0) })
    }

    private func mapEmailBack(_ entry: ProfileInfo.EmailEntry) -> VCardModule.VCard.Email {
        VCardModule.VCard.Email(address: entry.address, types: entry.types.map { mapEntryTypeBack($0) })
    }

    private func mapTelephone(_ tel: VCardModule.VCard.Telephone) -> ProfileInfo.TelephoneEntry {
        ProfileInfo.TelephoneEntry(number: tel.number, types: tel.types.map { mapEntryType($0) })
    }

    private func mapTelephoneBack(_ entry: ProfileInfo.TelephoneEntry) -> VCardModule.VCard.Telephone {
        VCardModule.VCard.Telephone(number: entry.number, types: entry.types.map { mapEntryTypeBack($0) })
    }

    private func mapAddress(_ adr: VCardModule.VCard.Address) -> ProfileInfo.AddressEntry {
        ProfileInfo.AddressEntry(
            street: adr.street,
            locality: adr.locality,
            region: adr.region,
            postalCode: adr.postalCode,
            country: adr.country,
            types: adr.types.map { mapEntryType($0) }
        )
    }

    private func mapAddressBack(_ entry: ProfileInfo.AddressEntry) -> VCardModule.VCard.Address {
        VCardModule.VCard.Address(
            street: entry.street,
            locality: entry.locality,
            region: entry.region,
            postalCode: entry.postalCode,
            country: entry.country,
            types: entry.types.map { mapEntryTypeBack($0) }
        )
    }
}
