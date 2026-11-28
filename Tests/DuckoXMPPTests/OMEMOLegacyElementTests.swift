import Foundation
import Testing
@testable import DuckoXMPP

/// The legacy device list, bundle and `<encrypted>` element against the ones the reference implementation wrote.
struct OMEMOLegacyElementTests {
    private let module = OMEMOModule(pepModule: PEPModule())

    // MARK: - Device List

    @Test(arguments: ["alice", "bob"])
    func `a device list has the reference's shape and reads back as its device`(device name: String) throws {
        let device = try OMEMOLegacyFixtures.device(name)

        let built = module.buildLegacyDeviceListElement([device.deviceID])

        #expect(try stanza(built.xmlString) == stanza(device.deviceList))
        #expect(try module.parseDeviceList(stanza(device.deviceList)) == [device.deviceID])
    }

    // MARK: - Bundle

    @Test(arguments: ["alice", "bob"])
    func `the reference bundle reads as its keys without the type byte and builds back to its shape`(device name: String) throws {
        let device = try OMEMOLegacyFixtures.device(name)

        let parsed = try #require(try module.parseLegacyBundleElement(stanza(device.bundle), deviceID: device.deviceID))
        let rebuilt = module.buildLegacyBundleElement(parsed)

        #expect(parsed.deviceID.value == device.deviceID)
        #expect(parsed.identityKey == Array(device.identityKey.agreementPublicKey))
        #expect(parsed.signedPreKeyID == device.signedPreKey.id)
        #expect(parsed.signedPreKey == Array(device.signedPreKey.publicKey))
        #expect(parsed.signedPreKeySignature == Array(device.signedPreKey.publishedSignature))
        #expect(parsed.preKeys.map(\.id) == device.preKeys.map(\.id))
        #expect(parsed.preKeys.map(\.publicKey) == device.preKeys.map { Array($0.publicKey) })
        #expect(try stanza(rebuilt.xmlString) == stanza(device.bundle))
    }

    @Test(arguments: ["alice", "bob"])
    func `a Ducko bundle carries the reference keys and a signature that verifies`(device name: String) throws {
        let device = try OMEMOLegacyFixtures.device(name)

        let built = try module.buildLegacyBundleElement(OMEMOPreKeyManager.buildLegacyBundle(
            deviceID: OMEMODeviceID(value: device.deviceID),
            identityKeyPair: device.restoredIdentityKey(), signedPreKey: device.restoredSignedPreKey(), preKeys: device.restoredPreKeys()
        ))
        let parsed = try #require(try module.parseLegacyBundleElement(stanza(built.xmlString), deviceID: device.deviceID))
        let reference = try #require(try module.parseLegacyBundleElement(stanza(device.bundle), deviceID: device.deviceID))

        #expect(parsed.identityKey == reference.identityKey)
        #expect(parsed.signedPreKeyID == reference.signedPreKeyID)
        #expect(parsed.signedPreKey == reference.signedPreKey)
        #expect(parsed.preKeys.map(\.id) == reference.preKeys.map(\.id))
        #expect(parsed.preKeys.map(\.publicKey) == reference.preKeys.map(\.publicKey))
        #expect(OMEMOLegacySignature.verify(
            parsed.signedPreKeySignature, signedPreKey: parsed.signedPreKey, identityCurveKey: parsed.identityKey
        ))
    }

    enum BundleKey: CaseIterable {
        case identityKey, signedPreKeyPublic
    }

    @Test(arguments: BundleKey.allCases)
    func `a bundle whose identity or signed pre-key lacks the type byte or its length is rejected`(key: BundleKey) throws {
        let device = try OMEMOLegacyFixtures.device("alice")
        let element = try stanza(device.bundle)
        let raw = switch key {
        case .identityKey: Array(device.identityKey.agreementPublicKey)
        case .signedPreKeyPublic: Array(device.signedPreKey.publicKey)
        }

        for malformed in [raw, [0x06] + raw, [0x05] + raw.dropLast(), [0x05] + raw + [0x00]] {
            let bundle = try Self.replacingText(of: "\(key)", in: element, with: Base64.encode(malformed))

            #expect(module.parseLegacyBundleElement(bundle, deviceID: device.deviceID) == nil)
        }
    }

    @Test func `a pre-key without the type byte or with a non-numeric id is left out`() throws {
        let device = try OMEMOLegacyFixtures.device("alice")
        let first = try #require(device.preKeys.first)
        let second = try #require(device.preKeys.dropFirst().first)
        let firstText = Base64.encode([0x05] + Array(first.publicKey))
        let secondID = "preKeyId=\"\(second.id)\""
        let xml = device.bundle
            .replacingOccurrences(of: firstText, with: Base64.encode(Array(first.publicKey)))
            .replacingOccurrences(of: secondID, with: "preKeyId=\"two\"")
        #expect(xml.contains(secondID) == false)

        let parsed = try #require(try module.parseLegacyBundleElement(stanza(xml), deviceID: device.deviceID))

        #expect(parsed.preKeys.map(\.id) == device.preKeys.dropFirst(2).map(\.id))
    }

    @Test func `a bundle with a non-numeric signed pre-key id is rejected`() throws {
        let device = try OMEMOLegacyFixtures.device("alice")
        let id = "signedPreKeyId=\"\(device.signedPreKey.id)\""
        #expect(device.bundle.contains(id))

        let bundle = try stanza(device.bundle.replacingOccurrences(of: id, with: "signedPreKeyId=\"one\""))

        #expect(module.parseLegacyBundleElement(bundle, deviceID: device.deviceID) == nil)
    }

    // MARK: - Encrypted Element

    @Test func `every reference element reads as its keys, IV and payload and builds back to its shape`() throws {
        let devices = try ["alice": OMEMOLegacyFixtures.device("alice"), "bob": OMEMOLegacyFixtures.device("bob")]
        for message in try OMEMOLegacyFixtures.conversation().messages {
            let sender = try #require(devices[message.sender])
            let recipient = try #require(devices.first { $0.key != message.sender }?.value)
            let keyData = message.keyExchange.map { Array($0.bytes) } ?? Array(message.authenticatedMessage.bytes)
            let payload = try message.payload.map { try Array(#require(Data(base64Encoded: $0))) }

            let parsed = try module.parseLegacyEncryptedElement(stanza(message.encrypted))
            let rebuilt = module.buildLegacyEncryptedElement(
                keys: parsed.keys.map { module.buildLegacyKeyElement(deviceID: $0.rid, data: $0.data, isPreKey: $0.isPreKey) },
                iv: parsed.iv, payload: parsed.payload, senderDeviceID: parsed.sid
            )

            #expect(parsed == OMEMOModule.ParsedLegacyEncrypted(
                sid: sender.deviceID,
                keys: [.init(rid: recipient.deviceID, data: keyData, isPreKey: message.keyExchange != nil)],
                iv: Array(message.iv), payload: payload
            ))
            #expect(try stanza(rebuilt.xmlString) == stanza(message.encrypted))
        }
    }

    @Test func `keys stay flat by device, and a key transport has no payload`() throws {
        let keys = [
            module.buildLegacyKeyElement(deviceID: 1, data: [1], isPreKey: false),
            module.buildLegacyKeyElement(deviceID: 2, data: [2], isPreKey: true)
        ]

        let built = module.buildLegacyEncryptedElement(keys: keys, iv: [9, 9], payload: nil, senderDeviceID: 7)
        let parsed = try module.parseLegacyEncryptedElement(stanza(built.xmlString))

        #expect(built.child(named: "header")?.children(named: "key").count == 2)
        #expect(parsed == OMEMOModule.ParsedLegacyEncrypted(
            sid: 7, keys: [.init(rid: 1, data: [1], isPreKey: false), .init(rid: 2, data: [2], isPreKey: true)],
            iv: [9, 9], payload: nil
        ))
    }

    @Test(arguments: ["1", "true"])
    func `a prekey attribute of true or 1 marks a key exchange`(value: String) throws {
        let xml = try Self.keyExchangeElement().replacingOccurrences(of: "prekey=\"true\"", with: "prekey=\"\(value)\"")

        let parsed = try module.parseLegacyEncryptedElement(stanza(xml))

        #expect(parsed.keys.map(\.isPreKey) == [true])
    }

    enum Malformation: CaseIterable {
        case emptyPayload, whitespacePayload, missingIV, emptyIV, missingSID, nonNumericSID, nonNumericRID,
             unknownPreKeyValue, emptyKey
    }

    @Test(arguments: Malformation.allCases)
    func `a malformed encrypted element is rejected`(malformation: Malformation) throws {
        let original = try Self.keyExchangeElement()
        let xml = switch malformation {
        case .emptyPayload: original.replacingOccurrences(of: "<payload>[^<]*</payload>", with: "<payload/>", options: .regularExpression)
        case .whitespacePayload: original.replacingOccurrences(of: "<payload>[^<]*</payload>", with: "<payload> </payload>", options: .regularExpression)
        case .missingIV: original.replacingOccurrences(of: "<iv>[^<]*</iv>", with: "", options: .regularExpression)
        case .emptyIV: original.replacingOccurrences(of: "<iv>[^<]*</iv>", with: "<iv/>", options: .regularExpression)
        case .missingSID: original.replacingOccurrences(of: " sid=\"[0-9]+\"", with: "", options: .regularExpression)
        case .nonNumericSID: original.replacingOccurrences(of: "sid=\"[0-9]+\"", with: "sid=\"alice\"", options: .regularExpression)
        case .nonNumericRID: original.replacingOccurrences(of: "rid=\"[0-9]+\"", with: "rid=\"bob\"", options: .regularExpression)
        case .unknownPreKeyValue: original.replacingOccurrences(of: "prekey=\"true\"", with: "prekey=\"yes\"")
        case .emptyKey: original.replacingOccurrences(of: ">[^<]*</key>", with: "></key>", options: .regularExpression)
        }
        #expect(xml != original)
        let expected: OMEMOModuleError = switch malformation {
        case .emptyPayload, .whitespacePayload: .invalidPayload
        case .missingIV, .missingSID, .nonNumericSID, .nonNumericRID, .unknownPreKeyValue: .invalidHeader
        case .emptyIV, .emptyKey: .invalidKeyData
        }

        #expect(throws: expected) {
            try module.parseLegacyEncryptedElement(stanza(xml))
        }
    }

    // MARK: - Helpers

    /// The first message's `<encrypted>` element, a key exchange with a payload.
    private static func keyExchangeElement() throws -> String {
        let message = try #require(try OMEMOLegacyFixtures.conversation().messages.first)
        #expect(message.keyExchange != nil && message.payload != nil)
        return message.encrypted
    }

    /// `element` with the text of its child `childName` replaced, keeping the child's attributes.
    private static func replacingText(of childName: String, in element: DuckoXMPP.XMLElement, with text: String) throws -> DuckoXMPP.XMLElement {
        var element = element
        var child = try #require(element.child(named: childName))
        let index = try #require(element.children.firstIndex(of: .element(child)))
        child.children = [.text(text)]
        element.children[index] = .element(child)
        return element
    }
}
