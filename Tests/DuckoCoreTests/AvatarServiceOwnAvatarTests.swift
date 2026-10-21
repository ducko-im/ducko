import CoreGraphics
import DuckoTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let validPNG = Data(base64Encoded: AvatarPayloads.validPNGBase64) ?? Data()

/// A solid-colour JPEG of the given size, with `properties` such as an EXIF orientation.
private func jpegData(width: Int, height: Int, properties: [CFString: Any] = [:]) throws -> Data {
    try imageData(width: width, height: height, type: .jpeg, properties: properties)
}

/// A solid-colour picture of the given size and type.
private func imageData(width: Int, height: Int, type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

/// Answers every own-vCard get on `transport` with a vCard whose photo is the valid PNG, and every disco#info query
/// with no features, so the account has no PEP.
private func autoAnswerOwnVCardAndDisco(on transport: MockTransport) async {
    await transport.autoReply { stanza in
        guard let id = extractIQID(from: stanza) else { return nil }
        if isOwnVCardGet(stanza) {
            return "<iq type='result' id='\(id)'>\(vcardBody(binval: AvatarPayloads.validPNGBase64))</iq>"
        }
        if stanza.contains(XMPPNamespaces.discoInfo) {
            return "<iq type='result' id='\(id)'><query xmlns='\(XMPPNamespaces.discoInfo)'/></iq>"
        }
        return nil
    }
}

/// Answers the first own-vCard get sent on `transport` with `vcard`.
private func answerOwnVCardGet(on transport: MockTransport, with vcard: String) async throws {
    let get = try await sentStanza(on: transport, matching: isOwnVCardGet)
    let id = try #require(extractIQID(from: get))
    await transport.simulateReceive("<iq type='result' id='\(id)'>\(vcard)</iq>")
}

/// Answers every own-vCard get on `transport` with item-not-found, as a server holding no vCard may (XEP-0153 §4.1.3),
/// every disco#info query with a PEP service, and every set with a result.
private func autoAnswerWithoutOwnVCard(on transport: MockTransport) async {
    await transport.autoReply { stanza in
        guard let id = extractIQID(from: stanza) else { return nil }
        if isOwnVCardGet(stanza) {
            return "<iq type='error' id='\(id)'><error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
        }
        if stanza.contains(XMPPNamespaces.discoInfo) {
            return """
            <iq type='result' id='\(id)'><query xmlns='\(XMPPNamespaces.discoInfo)'>\
            <identity category='pubsub' type='pep'/><feature var='\(XMPPNamespaces.pubsubPublish)'/></query></iq>
            """
        }
        return stanza.contains("type=\"set\"") ? "<iq type='result' id='\(id)'/>" : nil
    }
}

/// The last presence broadcast to contacts (sent without a `to`).
private func lastBroadcastPresence(on transport: MockTransport) async throws -> String {
    let sent = await transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
    return try #require(sent.last { $0.contains("<presence") && !$0.contains(" to=") })
}

private func ownResource(_ resource: String) throws -> FullJID {
    try #require(FullJID.parse("\(testJIDString)/\(resource)"))
}

// MARK: - Tests

extension AvatarServiceTests {
    struct PNGPublishing {
        @Test
        @MainActor
        func `a JPEG is published as PNG under the PNG's SHA-1`() async throws {
            let fixture = try await connectWithPresenceModule()
            let jpeg = try jpegData(width: 2, height: 3)

            let publishTask = Task { @MainActor in
                try await fixture.service.publishAvatar(imageData: jpeg, accountID: fixture.accountID)
            }
            try await answerAccountDiscoInfo(on: fixture.transport1)
            let dataPublish = try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarData) }
            let metadataPublish = try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarMetadata) }
            try await answerOwnVCardGet(on: fixture.transport1, with: vcardBody(binval: nil))
            let vcardSet = try await ackMatchedSet(fixture.transport1, where: isVCardSet)
            let avatar = try await publishTask.value

            #expect(avatar.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
            #expect(avatar.mimeType == "image/png")
            #expect(avatar.hash == sha1Hex(Array(avatar.data)))
            #expect(dataPublish.contains("<item id=\"\(avatar.hash)\">"))
            #expect(dataPublish.contains(avatar.data.base64EncodedString()))
            #expect(metadataPublish.contains("id=\"\(avatar.hash)\""))
            #expect(metadataPublish.contains("type=\"image/png\""))
            #expect(metadataPublish.contains("width=\"2\"") && metadataPublish.contains("height=\"3\""))
            #expect(vcardSet.contains("<TYPE>image/png</TYPE>"))
            #expect(fixture.service.ownAvatarHash(for: fixture.accountID) == avatar.hash)

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        func `a large picture is scaled down to the avatar size`() throws {
            let png = try #require(PNGEncoder.encode(jpegData(width: 2048, height: 1200)))

            #expect(png.width == PNGEncoder.maxPixelSize)
            #expect(png.height == 300)
        }

        @Test
        func `a picture taken on its side is published upright`() throws {
            // EXIF orientation 6: the stored pixels are turned a quarter to the left of how the picture is shown.
            let jpeg = try jpegData(width: 40, height: 20, properties: [kCGImagePropertyOrientation: 6])
            let png = try #require(PNGEncoder.encode(jpeg))

            #expect(png.width == 20)
            #expect(png.height == 40)
        }

        @Test
        @MainActor
        func `a picture file over the avatar cap is published scaled down`() async throws {
            let fixture = try await connectWithPresenceModule()
            await autoAnswerWithoutOwnVCard(on: fixture.transport1)
            // An uncompressed TIFF, so the file is over the cap.
            let tiff = try imageData(
                width: 2000, height: 2000, type: .tiff,
                properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]]
            )
            try #require(tiff.count > AvatarLimits.maxBytes)

            let avatar = try await fixture.service.publishAvatar(imageData: tiff, accountID: fixture.accountID)

            let png = try #require(PNGEncoder.encode(avatar.data))
            #expect(png.width == PNGEncoder.maxPixelSize && png.height == PNGEncoder.maxPixelSize)
            #expect(fixture.service.ownAvatarHash(for: fixture.accountID) == avatar.hash)

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `without PEP on the account nothing is published and the error says why`() async throws {
            let fixture = try await connectWithPresenceModule()

            let publishTask = Task { @MainActor in
                try await fixture.service.publishAvatar(imageData: validPNG, accountID: fixture.accountID)
            }
            try await answerAccountDiscoInfo(on: fixture.transport1, pep: false)
            let error = await #expect(throws: AvatarService.AvatarServiceError.self) { try await publishTask.value }

            #expect(error?.localizedDescription == "The server cannot share avatars, so the picture was not published")
            let sent = await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("<publish") })

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `a picture the vCard could not store is not advertised`() async throws {
            let fixture = try await connectWithPresenceModule()

            let publishTask = Task { @MainActor in
                try await fixture.service.publishAvatar(imageData: validPNG, accountID: fixture.accountID)
            }
            try await answerAccountDiscoInfo(on: fixture.transport1)
            try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarData) }
            try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarMetadata) }
            try await answerOwnVCardGet(on: fixture.transport1, with: vcardBody(binval: nil))
            let vcardSet = try #require(await fixture.transport1.waitForSent(matching: isVCardSet))
            let setID = try #require(extractIQID(from: vcardSet))
            await fixture.transport1.simulateReceive(
                "<iq type='error' id='\(setID)'><error type='wait'><resource-constraint xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            )
            let avatar = try await publishTask.value

            #expect(fixture.service.ownAvatarHash(for: fixture.accountID) == nil)
            let sent = await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("<photo>\(avatar.hash)</photo>") })

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `without PEP on the account a removal clears only the vCard photo`() async throws {
            let fixture = try await connectWithPresenceModule()
            await fixture.transport1.autoReply { stanza in
                guard let id = extractIQID(from: stanza) else { return nil }
                if isOwnVCardGet(stanza) {
                    return "<iq type='result' id='\(id)'>\(vcardBody(binval: AvatarPayloads.validPNGBase64))</iq>"
                }
                if stanza.contains(XMPPNamespaces.discoInfo) {
                    return "<iq type='result' id='\(id)'><query xmlns='\(XMPPNamespaces.discoInfo)'/></iq>"
                }
                return stanza.contains("type=\"set\"") ? "<iq type='result' id='\(id)'/>" : nil
            }

            try await fixture.service.removeAvatar(accountID: fixture.accountID)

            let sent = await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("<publish") })
            let vcardSet = try #require(sent.first(where: isVCardSet))
            #expect(!vcardSet.contains("<PHOTO>"))
            #expect(try await lastBroadcastPresence(on: fixture.transport1).contains("<photo/>"))

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `a removal the vCard kept is reported and the avatar stays advertised`() async throws {
            let fixture = try await connectWithPresenceModule()
            let presenceModule = try #require(await fixture.client1.module(ofType: PresenceModule.self))
            presenceModule.setOwnAvatarHash("old-hash")
            fixture.service.setOwnAvatarHashForTesting("old-hash", accountID: fixture.accountID)

            let removeTask = Task { @MainActor in
                try await fixture.service.removeAvatar(accountID: fixture.accountID)
            }
            try await answerAccountDiscoInfo(on: fixture.transport1)
            try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarMetadata) }
            try await answerOwnVCardGet(on: fixture.transport1, with: vcardBody(binval: AvatarPayloads.validPNGBase64))
            let vcardSet = try #require(await fixture.transport1.waitForSent(matching: isVCardSet))
            let setID = try #require(extractIQID(from: vcardSet))
            await fixture.transport1.simulateReceive(
                "<iq type='error' id='\(setID)'><error type='wait'><resource-constraint xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            )
            let error = await #expect(throws: AvatarService.AvatarServiceError.self) { try await removeTask.value }

            #expect(error?.localizedDescription == AvatarService.AvatarServiceError.pictureNotRemoved.localizedDescription)
            #expect(fixture.service.ownAvatarHash(for: fixture.accountID) == "old-hash")
            let sent = await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("<presence") && $0.contains("<photo/>") })

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `once its own publish was notified, the same avatar set again on another device is followed`() async throws {
            let fixture = try await connectWithPresenceModule()
            let published = try sha1Hex(Array(#require(PNGEncoder.encode(validPNG)).data))
            let vcardPhoto = sha1Hex(Array(validPNG))
            try #require(published != vcardPhoto)
            let ownJID = try #require(BareJID.parse(testJIDString))
            func metadata(_ id: String) -> XMPPEvent {
                .pepItemsPublished(from: ownJID, node: XMPPNamespaces.avatarMetadata, items: [avatarMetadataItem(id: id)])
            }
            func vcardReads() async -> Int {
                await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter(isOwnVCardGet).count
            }

            let publishTask = Task { @MainActor in
                try await fixture.service.publishAvatar(imageData: validPNG, accountID: fixture.accountID)
            }
            try await answerAccountDiscoInfo(on: fixture.transport1)
            try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarData) }
            try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarMetadata) }
            try await answerOwnVCardGet(on: fixture.transport1, with: vcardBody(binval: nil))
            try await ackMatchedSet(fixture.transport1, where: isVCardSet)
            _ = try await publishTask.value
            await fixture.service.handleEvent(metadata(published), accountID: fixture.accountID)
            #expect(await vcardReads() == 1)

            // Another device sets a different avatar, which the vCard now holds, and then sets this one again.
            await autoAnswerOwnVCardAndDisco(on: fixture.transport1)
            await fixture.service.handleEvent(metadata("another-device-avatar"), accountID: fixture.accountID)
            try #require(fixture.service.ownAvatarHash(for: fixture.accountID) == vcardPhoto)
            await fixture.service.handleEvent(metadata(published), accountID: fixture.accountID)

            #expect(await vcardReads() == 3)

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `the notification of this device's own publish is not taken for another device's change`() async throws {
            let fixture = try await connectWithPresenceModule()
            let hash = try sha1Hex(Array(#require(PNGEncoder.encode(validPNG)).data))
            let ownJID = try #require(BareJID.parse(testJIDString))

            let publishTask = Task { @MainActor in
                try await fixture.service.publishAvatar(imageData: validPNG, accountID: fixture.accountID)
            }
            try await answerAccountDiscoInfo(on: fixture.transport1)
            try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarData) }
            try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarMetadata) }
            // The server's notification lands while the vCard is still being updated.
            let echo = XMPPEvent.pepItemsPublished(from: ownJID, node: XMPPNamespaces.avatarMetadata, items: [avatarMetadataItem(id: hash)])
            let echoHandled = try await boundedOutcome { await fixture.service.handleEvent(echo, accountID: fixture.accountID) }
            #expect(echoHandled != nil)
            try await answerOwnVCardGet(on: fixture.transport1, with: vcardBody(binval: nil))
            try await ackMatchedSet(fixture.transport1, where: isVCardSet)
            _ = try await publishTask.value

            let sent = await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(sent.filter(isOwnVCardGet).count == 1)

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }
    }

    /// A server that holds no vCard for the account may answer item-not-found, which reads as an empty vCard.
    struct MissingVCard {
        @Test
        @MainActor
        func `signing in advertises that the account has no avatar`() async throws {
            let fixture = try await connectWithPresenceModule()
            await autoAnswerWithoutOwnVCard(on: fixture.transport1)

            try await fixture.service.handleEvent(.connected(#require(FullJID.parse("\(testJIDString)/ducko"))), accountID: fixture.accountID)

            #expect(try await lastBroadcastPresence(on: fixture.transport1).contains("<photo/>"))

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `a first avatar creates the vCard and is advertised`() async throws {
            let fixture = try await connectWithPresenceModule()
            await autoAnswerWithoutOwnVCard(on: fixture.transport1)

            let avatar = try await fixture.service.publishAvatar(imageData: validPNG, accountID: fixture.accountID)

            let sent = await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            let vcardSet = try #require(sent.first(where: isVCardSet))
            #expect(vcardSet.contains("<BINVAL>\(avatar.data.base64EncodedString())</BINVAL>"))
            #expect(fixture.service.ownAvatarHash(for: fixture.accountID) == avatar.hash)

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }
    }

    struct OtherOwnDevices {
        enum Change: CaseIterable {
            case vcardHash
            case pepMetadata
        }

        @Test(arguments: Change.allCases)
        @MainActor
        func `another device's avatar change is read from the vCard and advertised`(change: Change) async throws {
            let fixture = try await connectWithPresenceModule()
            let hash = sha1Hex(Array(validPNG))
            let phone = try ownResource("phone")
            let event: XMPPEvent = switch change {
            case .vcardHash:
                .vcardAvatarHashReceived(from: .full(phone), hash: hash)
            case .pepMetadata:
                .pepItemsPublished(from: phone.bareJID, node: XMPPNamespaces.avatarMetadata, items: [avatarMetadataItem(id: hash)])
            }
            await autoAnswerOwnVCardAndDisco(on: fixture.transport1)

            await fixture.service.handleEvent(event, accountID: fixture.accountID)

            #expect(fixture.service.ownAvatarHash(for: fixture.accountID) == hash)
            #expect(try await lastBroadcastPresence(on: fixture.transport1).contains("<photo>\(hash)</photo>"))

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `another device's different hash stops the old one being advertised before the vCard is read`() async throws {
            let fixture = try await connectWithPresenceModule()
            let presenceModule = try #require(await fixture.client1.module(ofType: PresenceModule.self))
            presenceModule.setOwnAvatarHash("old-hash")
            fixture.service.setOwnAvatarHashForTesting("old-hash", accountID: fixture.accountID)
            let hash = sha1Hex(Array(validPNG))
            await autoAnswerOwnVCardAndDisco(on: fixture.transport1)
            let sentBefore = await fixture.transport1.sentBytes.count

            try await fixture.service.handleEvent(.vcardAvatarHashReceived(from: .full(ownResource("phone")), hash: hash), accountID: fixture.accountID)

            let sent = await fixture.transport1.sentBytes[sentBefore...].map { String(decoding: $0, as: UTF8.self) }
            let reset = try #require(sent.firstIndex { $0.contains("<presence") && $0.contains("<x xmlns=\"\(XMPPNamespaces.vcardAvatarUpdate)\"/>") })
            let vcardGet = try #require(sent.firstIndex(where: isOwnVCardGet))
            #expect(reset < vcardGet)
            #expect(try await lastBroadcastPresence(on: fixture.transport1).contains("<photo>\(hash)</photo>"))

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `this resource's own presence echo fetches nothing`() async throws {
            let fixture = try await connectWithPresenceModule()
            let echo = try XMPPEvent.vcardAvatarHashReceived(from: .full(ownResource("ducko")), hash: "other-hash")
            let sentBefore = await fixture.transport1.sentBytes.count

            let handled = try await boundedOutcome { await fixture.service.handleEvent(echo, accountID: fixture.accountID) }

            #expect(handled != nil)
            #expect(await fixture.transport1.sentBytes.count == sentBefore)

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `a resource without vCard avatars stops advertising until it goes offline`() async throws {
            let fixture = try await connectWithPresenceModule()
            let presenceModule = try #require(await fixture.client1.module(ofType: PresenceModule.self))
            let phone = try JID.full(ownResource("phone"))
            let ducko = try ownResource("ducko")
            let hash = sha1Hex(Array(validPNG))
            await autoAnswerOwnVCardAndDisco(on: fixture.transport1)

            var available = XMPPPresence()
            available.from = phone
            try presenceModule.handlePresence(available)
            await fixture.service.handleEvent(.presenceUpdated(from: phone, presence: available), accountID: fixture.accountID)
            await fixture.service.handleEvent(.connected(ducko), accountID: fixture.accountID)

            #expect(fixture.service.ownAvatarHash(for: fixture.accountID) == hash)
            let withheld = try await lastBroadcastPresence(on: fixture.transport1)
            #expect(withheld.contains("<x xmlns=\"\(XMPPNamespaces.vcardAvatarUpdate)\"/>"))

            var unavailable = XMPPPresence(type: .unavailable)
            unavailable.from = phone
            try presenceModule.handlePresence(unavailable)
            await fixture.service.handleEvent(.presenceUpdated(from: phone, presence: unavailable), accountID: fixture.accountID)

            #expect(try await lastBroadcastPresence(on: fixture.transport1).contains("<photo>\(hash)</photo>"))
            let sent = await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(sent.filter(isOwnVCardGet).count == 2)

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }
    }
}
