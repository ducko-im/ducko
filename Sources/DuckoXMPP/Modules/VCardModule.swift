import struct os.OSAllocatedUnfairLock

/// Implements XEP-0054 vCard-temp — fetches, caches, and publishes vCards.
public final class VCardModule: XMPPModule, Sendable {
    // MARK: - Types

    /// Entry type marker for email, telephone, and address fields.
    public enum EntryType: String, Sendable {
        case home = "HOME"
        case work = "WORK"
    }

    /// A parsed vCard-temp result.
    public struct VCard: Sendable {
        public var fullName: String?
        public var nickname: String?
        public var name: Name?
        public var emails: [Email]
        public var telephones: [Telephone]
        public var addresses: [Address]
        public var organization: String?
        public var title: String?
        public var role: String?
        public var url: String?
        public var birthday: String?
        public var note: String?
        public var photoData: [UInt8]?
        public var photoType: String?
        public var photoHash: String?

        /// The original raw XML element from the server, used for lossless round-tripping.
        public var rawElement: XMLElement?

        public struct Name: Sendable {
            public var familyName: String?
            public var givenName: String?
            public var middleName: String?
            public var prefix: String?
            public var suffix: String?

            public init(
                familyName: String? = nil,
                givenName: String? = nil,
                middleName: String? = nil,
                prefix: String? = nil,
                suffix: String? = nil
            ) {
                self.familyName = familyName
                self.givenName = givenName
                self.middleName = middleName
                self.prefix = prefix
                self.suffix = suffix
            }
        }

        public struct Email: Sendable {
            public var address: String
            public var types: [EntryType]

            public init(address: String, types: [EntryType] = []) {
                self.address = address
                self.types = types
            }
        }

        public struct Telephone: Sendable {
            public var number: String
            public var types: [EntryType]

            public init(number: String, types: [EntryType] = []) {
                self.number = number
                self.types = types
            }
        }

        public struct Address: Sendable {
            public var street: String?
            public var locality: String?
            public var region: String?
            public var postalCode: String?
            public var country: String?
            public var types: [EntryType]

            public init(
                street: String? = nil,
                locality: String? = nil,
                region: String? = nil,
                postalCode: String? = nil,
                country: String? = nil,
                types: [EntryType] = []
            ) {
                self.street = street
                self.locality = locality
                self.region = region
                self.postalCode = postalCode
                self.country = country
                self.types = types
            }
        }

        public init(
            fullName: String? = nil,
            nickname: String? = nil,
            name: Name? = nil,
            emails: [Email] = [],
            telephones: [Telephone] = [],
            addresses: [Address] = [],
            organization: String? = nil,
            title: String? = nil,
            role: String? = nil,
            url: String? = nil,
            birthday: String? = nil,
            note: String? = nil,
            photoData: [UInt8]? = nil,
            photoType: String? = nil,
            photoHash: String? = nil
        ) {
            self.fullName = fullName
            self.nickname = nickname
            self.name = name
            self.emails = emails
            self.telephones = telephones
            self.addresses = addresses
            self.organization = organization
            self.title = title
            self.role = role
            self.url = url
            self.birthday = birthday
            self.note = note
            self.photoData = photoData
            self.photoType = photoType
            self.photoHash = photoHash
        }
    }

    // MARK: - State

    private struct State {
        var context: ModuleContext?
        var cache: [BareJID: VCard] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.vcard]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Public API

    /// Fetches the vCard for a bare JID, using cache unless `forceRefresh` is true.
    public func fetchVCard(for jid: BareJID, forceRefresh: Bool = false) async throws -> VCard? {
        try await fetchVCardImpl(cacheKey: jid, to: .bare(jid), forceRefresh: forceRefresh)
    }

    /// Fetches the user's own vCard (no `to` attribute per XEP-0054).
    public func fetchOwnVCard(forceRefresh: Bool = false) async throws -> VCard? {
        guard let context = state.withLock({ $0.context }), let bareJID = context.connectedJID()?.bareJID else { return nil }
        return try await fetchVCardImpl(cacheKey: bareJID, to: nil, forceRefresh: forceRefresh)
    }

    // MARK: - Shared Fetch

    private func fetchVCardImpl(cacheKey: BareJID, to: JID?, forceRefresh: Bool) async throws -> VCard? {
        if !forceRefresh, let cached = state.withLock({ $0.cache[cacheKey] }) {
            return cached
        }

        guard let context = state.withLock({ $0.context }) else { return nil }

        var iq = XMPPIQ(type: .get, to: to, id: context.generateID())
        let vcardElement = XMLElement(name: "vCard", namespace: XMPPNamespaces.vcard)
        iq.element.addChild(vcardElement)

        guard let result = try await context.sendIQ(iq) else { return nil }

        let vcard = parseVCard(result)
        state.withLock { $0.cache[cacheKey] = vcard }
        return vcard
    }

    /// Publishes the user's own vCard (no `to` attribute per XEP-0054).
    public func publishVCard(_ vcard: VCard) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        iq.element.addChild(serializeVCard(vcard))

        _ = try await context.sendIQ(iq)

        if let bareJID = context.connectedJID()?.bareJID {
            state.withLock { $0.cache[bareJID] = vcard }
        }
    }

    // MARK: - Parsing

    private func parseVCard(_ element: XMLElement) -> VCard {
        let fullName = element.childText(named: "FN")
        let nickname = element.childText(named: "NICKNAME")
        let name = parseName(element)
        let emails = parseEmails(element)
        let telephones = parseTelephones(element)
        let addresses = parseAddresses(element)
        let organization = parseOrganization(element)
        let title = element.childText(named: "TITLE")
        let role = element.childText(named: "ROLE")
        let url = element.childText(named: "URL")
        let birthday = element.childText(named: "BDAY")
        let note = element.childText(named: "DESC")

        var photoData: [UInt8]?
        var photoType: String?
        var photoHash: String?
        if let photo = element.child(named: "PHOTO") {
            photoType = photo.childText(named: "TYPE")
            if let binval = photo.childText(named: "BINVAL"),
               let decoded = Base64.decode(binval) {
                photoData = decoded
                photoHash = sha1Hex(decoded)
            }
        }

        var vcard = VCard(
            fullName: fullName,
            nickname: nickname,
            name: name,
            emails: emails,
            telephones: telephones,
            addresses: addresses,
            organization: organization,
            title: title,
            role: role,
            url: url,
            birthday: birthday,
            note: note,
            photoData: photoData,
            photoType: photoType,
            photoHash: photoHash
        )
        vcard.rawElement = element
        return vcard
    }

    private func parseName(_ element: XMLElement) -> VCard.Name? {
        guard let n = element.child(named: "N") else { return nil }
        let name = VCard.Name(
            familyName: n.childText(named: "FAMILY"),
            givenName: n.childText(named: "GIVEN"),
            middleName: n.childText(named: "MIDDLE"),
            prefix: n.childText(named: "PREFIX"),
            suffix: n.childText(named: "SUFFIX")
        )
        if name.familyName == nil, name.givenName == nil, name.middleName == nil,
           name.prefix == nil, name.suffix == nil {
            return nil
        }
        return name
    }

    private func parseEmails(_ element: XMLElement) -> [VCard.Email] {
        element.children(named: "EMAIL").compactMap { email in
            guard let address = email.childText(named: "USERID") else { return nil }
            return VCard.Email(address: address, types: parseEntryTypes(email))
        }
    }

    private func parseTelephones(_ element: XMLElement) -> [VCard.Telephone] {
        element.children(named: "TEL").compactMap { tel in
            guard let number = tel.childText(named: "NUMBER") else { return nil }
            return VCard.Telephone(number: number, types: parseEntryTypes(tel))
        }
    }

    private func parseAddresses(_ element: XMLElement) -> [VCard.Address] {
        element.children(named: "ADR").map { adr in
            VCard.Address(
                street: adr.childText(named: "STREET"),
                locality: adr.childText(named: "LOCALITY"),
                region: adr.childText(named: "REGION"),
                postalCode: adr.childText(named: "PCODE"),
                country: adr.childText(named: "CTRY"),
                types: parseEntryTypes(adr)
            )
        }
    }

    private func parseOrganization(_ element: XMLElement) -> String? {
        element.child(named: "ORG")?.childText(named: "ORGNAME")
    }

    private func parseEntryTypes(_ element: XMLElement) -> [EntryType] {
        var types: [EntryType] = []
        if element.child(named: "HOME") != nil { types.append(.home) }
        if element.child(named: "WORK") != nil { types.append(.work) }
        return types
    }

    // MARK: - Serialization

    private func serializeVCard(_ vcard: VCard) -> XMLElement {
        var element: XMLElement
        if let raw = vcard.rawElement {
            // Merge into original to preserve unsupported fields
            element = raw
            removeKnownStructuredChildren(&element)
        } else {
            element = XMLElement(name: "vCard", namespace: XMPPNamespaces.vcard)
        }
        serializeScalars(&element, vcard)
        serializeName(&element, vcard.name)
        serializeEmails(&element, vcard.emails)
        serializeTelephones(&element, vcard.telephones)
        serializeAddresses(&element, vcard.addresses)
        serializeOrganization(&element, vcard.organization)
        serializePhoto(&element, vcard)
        return element
    }

    /// Removes structured children that will be re-serialized.
    /// Scalar fields (FN, NICKNAME, etc.) are handled by `setChildText` which removes-then-adds.
    /// Keep in sync with the `serialize*` methods below.
    private func removeKnownStructuredChildren(_ element: inout XMLElement) {
        let structuredNames: Set = ["N", "EMAIL", "TEL", "ADR", "ORG", "PHOTO"]
        element.children.removeAll { node in
            guard case let .element(child) = node else { return false }
            return structuredNames.contains(child.name)
        }
    }

    private func serializeScalars(_ element: inout XMLElement, _ vcard: VCard) {
        element.setChildText(named: "FN", to: vcard.fullName)
        element.setChildText(named: "NICKNAME", to: vcard.nickname)
        element.setChildText(named: "TITLE", to: vcard.title)
        element.setChildText(named: "ROLE", to: vcard.role)
        element.setChildText(named: "URL", to: vcard.url)
        element.setChildText(named: "BDAY", to: vcard.birthday)
        element.setChildText(named: "DESC", to: vcard.note)
    }

    private func serializeName(_ element: inout XMLElement, _ name: VCard.Name?) {
        guard let name else { return }
        var n = XMLElement(name: "N")
        n.setChildText(named: "FAMILY", to: name.familyName)
        n.setChildText(named: "GIVEN", to: name.givenName)
        n.setChildText(named: "MIDDLE", to: name.middleName)
        n.setChildText(named: "PREFIX", to: name.prefix)
        n.setChildText(named: "SUFFIX", to: name.suffix)
        element.addChild(n)
    }

    private func serializeEmails(_ element: inout XMLElement, _ emails: [VCard.Email]) {
        for email in emails {
            var e = XMLElement(name: "EMAIL")
            e.setChildText(named: "USERID", to: email.address)
            addTypeMarkers(&e, email.types)
            element.addChild(e)
        }
    }

    private func serializeTelephones(_ element: inout XMLElement, _ telephones: [VCard.Telephone]) {
        for tel in telephones {
            var t = XMLElement(name: "TEL")
            t.setChildText(named: "NUMBER", to: tel.number)
            addTypeMarkers(&t, tel.types)
            element.addChild(t)
        }
    }

    private func serializeAddresses(_ element: inout XMLElement, _ addresses: [VCard.Address]) {
        for adr in addresses {
            var a = XMLElement(name: "ADR")
            a.setChildText(named: "STREET", to: adr.street)
            a.setChildText(named: "LOCALITY", to: adr.locality)
            a.setChildText(named: "REGION", to: adr.region)
            a.setChildText(named: "PCODE", to: adr.postalCode)
            a.setChildText(named: "CTRY", to: adr.country)
            addTypeMarkers(&a, adr.types)
            element.addChild(a)
        }
    }

    private func serializeOrganization(_ element: inout XMLElement, _ organization: String?) {
        guard let organization else { return }
        var org = XMLElement(name: "ORG")
        org.setChildText(named: "ORGNAME", to: organization)
        element.addChild(org)
    }

    private func serializePhoto(_ element: inout XMLElement, _ vcard: VCard) {
        guard let photoData = vcard.photoData else { return }
        var photo = XMLElement(name: "PHOTO")
        if let photoType = vcard.photoType {
            photo.setChildText(named: "TYPE", to: photoType)
        }
        photo.setChildText(named: "BINVAL", to: Base64.encode(photoData))
        element.addChild(photo)
    }

    private func addTypeMarkers(_ element: inout XMLElement, _ types: [EntryType]) {
        for type in types {
            element.addChild(XMLElement(name: type.rawValue))
        }
    }
}
