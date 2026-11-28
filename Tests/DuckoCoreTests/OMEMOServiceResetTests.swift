import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contact = BareJID(localPart: "bob", domainPart: "example.com")!

/// A reset of the encryption sessions with a contact, run against bob's device 200 over the encrypted-send harness, or
/// with the account's other devices.
@MainActor
struct OMEMOServiceResetTests {
    /// The notes in the chat with bob.
    private func notes(in harness: EncryptedSendHarness) async throws -> [TimelineNote] {
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact })
        return try await harness.transcripts.fetchNotes(for: chat.id, since: nil, before: nil)
    }

    private func storedSession(_ data: UInt8, deviceID: UInt32 = 200) -> OMEMOStoredSession {
        OMEMOStoredSession(
            accountJID: testJIDString, peerJID: contact.description, peerDeviceID: deviceID, version: .omemo2,
            sessionData: Data([data]), associatedData: Data([data])
        )
    }

    /// A second service over the harness's account and store, with trust on first use as given, whose guard the
    /// harness's module uses as a module the service builds would.
    private func guardedService(trustOnFirstUse: Bool = true, in harness: EncryptedSendHarness) async throws -> OMEMOService {
        let service = OMEMOService(omemoStore: harness.omemoStore, trustOnFirstUse: { trustOnFirstUse })
        service.setAccountService(harness.accountService)
        service.setChatService(harness.chatService)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        module.configureTrustGuard(service.trustGuard(forAccountJID: testJIDString))
        return service
    }

    private func sentEncrypted(in harness: EncryptedSendHarness) async -> Bool {
        await harness.transport.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("<encrypted") }
    }

    /// The fingerprint the key of the device with `keys` is stored as when `format` shows it.
    private func storedFingerprint(of keys: OMEMOModule.OMEMOIdentityData, format: OMEMOWireFormat) throws -> String {
        try omemoFingerprint(of: OMEMOX3DH.identityKey(of: OMEMOIdentityKeyPair(rawRepresentation: keys.identityKeyRaw), format: format), format: format)
    }

    /// The Curve25519 key of the device with `keys`, as the user compares it: in eight groups of eight hex digits.
    private func displayedCurveKey(of keys: OMEMOModule.OMEMOIdentityData) throws -> String {
        let curveKey = try OMEMOIdentityKeyPair(rawRepresentation: keys.identityKeyRaw).agreementPrivateKey().publicKey.rawRepresentation
        let digits = Array(hexString(curveKey))
        return stride(from: 0, to: digits.count, by: 8).map { String(digits[$0 ..< $0 + 8]) }.joined(separator: " ")
    }

    /// Bob's device with `keys` reads the empty message the reset sent it in `version` and answers in that version.
    /// Returns the answer's body as this device reads it after a restart restored the stored sessions.
    private func answerReadAfterRestart(
        in harness: EncryptedSendHarness, version: OMEMOWireFormat, from keys: OMEMOModule.OMEMOIdentityData
    ) async throws -> String? {
        let account = try #require(BareJID.parse(testJIDString))
        let namespace = version == .omemo2 ? XMPPNamespaces.omemo : XMPPNamespaces.omemoLegacy
        let sent = try await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.hasPrefix("<message") }.map(parsed)
        var resetMessage = try XMPPMessage(element: #require(sent.last { $0.child(named: "encrypted", namespace: namespace) != nil }))
        resetMessage.from = JID.parse("\(testJIDString)/ducko")
        let bobsDevice = isolatedModule(keys: keys, connectedAs: contact)
        // Listed first, so reading the message fetches no list that could replace this one.
        bobsDevice.state.withLock { $0.deviceLists[version, default: [:]][account] = [100] }
        _ = bobsDevice.receiveArchivedMessage(resetMessage, sender: account, isRoomPrivateMessage: false, allowsKeyExchange: true)
        var body = DuckoXMPP.XMLElement(name: "body")
        body.addText("answer \(version)")
        let elements = try await bobsDevice.encryptMessage(
            content: [body], legacyBody: "answer \(version)", time: Date().formatted(.iso8601), to: account, recipientDeviceIDs: [100], ownDeviceIDs: []
        )
        var answer = XMPPMessage(type: .chat, to: JID.parse("\(testJIDString)/ducko"), id: "answer")
        answer.from = JID.parse("\(contact)/desktop")
        try answer.element.addChild(#require(version == .omemo2 ? elements.omemo2Encrypted : elements.legacyEncrypted))

        let restarted = isolatedModule(keys: harness.ownKeys, connectedAs: account)
        try await restarted.restoreSessions(harness.omemoStore.loadSessions(for: testJIDString).map { session in
            OMEMOModule.StoredSessionEntry(
                jid: contact, deviceID: session.peerDeviceID, version: session.version,
                sessionData: Array(session.sessionData), associatedData: Array(session.associatedData)
            )
        })
        guard case let .decrypted(decrypted)? = restarted.receiveArchivedMessage(
            answer, sender: contact, isRoomPrivateMessage: false, allowsKeyExchange: false
        ) else { return nil }
        return decrypted.message.body
    }

    /// The legacy session with bob's device `deviceID`, whose keys are `keys`, that this account's device builds from a
    /// bundle listing a pre-key.
    private func legacySession(
        with keys: OMEMOModule.OMEMOIdentityData, deviceID: UInt32 = 200, in harness: EncryptedSendHarness
    ) throws -> OMEMOModule.StoredSessionEntry {
        let builder = try isolatedModule(keys: harness.ownKeys, connectedAs: #require(BareJID.parse(testJIDString)))
        let bundle = try #require(builder.parseLegacyBundleElement(EncryptedSendHarness.legacyBundle(of: keys), deviceID: deviceID))
        _ = try builder.establishSession(
            sessionKey: SessionKey(jid: contact, deviceID: deviceID, version: .legacy), identity: builder.requireOwnIdentity(), bundle: bundle
        )
        return try #require(builder.exportSession(jid: contact, deviceID: deviceID, version: .legacy))
    }

    /// A module with `keys`, connected as `jid`, that sends nothing and fetches nothing.
    private func isolatedModule(keys: OMEMOModule.OMEMOIdentityData, connectedAs jid: BareJID) -> OMEMOModule {
        let context = ModuleContext(
            sendStanza: { _, onAccepted in onAccepted?() }, sendIQ: { _, _ in nil }, emitEvent: { _ in }, generateID: { "isolated-1" },
            connectedJID: { FullJID.parse("\(jid)/isolated") }, domain: "example.com"
        )
        let pepModule = PEPModule()
        pepModule.setUp(context)
        let module = OMEMOModule(pepModule: pepModule)
        module.setUp(context)
        module.configureIdentity(keys)
        module.handleSessionEstablished(resumed: true)
        return module
    }

    @Test func `A reset builds a new session with each listed device, sends it an empty message, stores it, and notes the reset`() async throws {
        let harness = try await EncryptedSendHarness.connect()

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report == OMEMOSessionResetReport(peerJID: contact.description, devices: [.init(deviceID: 200, outcome: .rebuilt(needsTrusting: false))]))
        #expect(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") } != nil)
        let sessions = try await harness.omemoStore.loadSessions(for: testJIDString)
        #expect(sessions.map(\.peerDeviceID) == [200])
        let note = try #require(await notes(in: harness).first)
        #expect(note.kind == .sessionsReset)
        #expect(note.detail == nil)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A device on one list. A legacy key is stored in its own form, and shown as the Curve25519 key it is.
    @Test(arguments: [OMEMOWireFormat.omemo2, .legacy])
    func `A reset that finds a device's key changed holds and stores the new key as untrusted, deletes the session, and notes both keys`(
        version: OMEMOWireFormat
    ) async throws {
        let harness = try await EncryptedSendHarness.connect(
            contactDevices: version == .omemo2 ? [200] : [], legacyDeviceLists: version == .legacy ? [contact: [200]] : [:]
        )
        // The harness builds its module without the service, which wires the account's guard into the modules it builds.
        let trustGuard = harness.omemoService.trustGuard(forAccountJID: testJIDString)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        module.configureTrustGuard(trustGuard)
        let previous = String(repeating: "ab", count: 32)
        trustGuard.merge(
            [OMEMOTrustGuard.StoredTrust(peer: contact, deviceID: 200, fingerprint: previous, decision: .granted)],
            loadedAfter: trustGuard.currentStamp()
        )
        try await harness.omemoStore.saveSession(storedSession(1))
        let bundleKeys = try version == .omemo2 ? harness.bob : #require(harness.legacyKeys[200])
        let new = try storedFingerprint(of: bundleKeys, format: version)

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: 200, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .keyChanged(previousFingerprint: previous, newFingerprint: new))])
        #expect(new.count == (version == .omemo2 ? 64 : 66))
        #expect(trustGuard.heldFingerprint(peer: contact, deviceID: 200) == new)
        #expect(trustGuard.refuses(OMEMODeviceKey(jid: contact, deviceID: 200)))
        let rows = try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString)
        #expect(rows.map { "\($0.deviceID) \($0.fingerprint) \($0.trustLevel)" } == ["200 \(new) untrusted"])
        #expect(try await harness.omemoStore.loadSessions(for: testJIDString).isEmpty)
        let detail = try #require(await notes(in: harness).first?.detail)
        #expect(detail.contains(OMEMODeviceInfo.formatFingerprint(previous)))
        #expect(try detail.contains(displayedCurveKey(of: bundleKeys)))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The versions are reset OMEMO 2 first, so depending on which version's key is held, the first bundle met carries
    /// the held key or another one. Only a version whose bundle carries the held key gets a session. The held key
    /// stays, and another key a bundle offers is reported and noted as refused.
    @Test(arguments: [true, false], [OMEMOWireFormat.omemo2, .legacy])
    func `A reset of a device on both lists rebuilds each version whose bundle carries the held key, and reports another key as refused`(
        legacySharesKey: Bool, heldVersion: OMEMOWireFormat
    ) async throws {
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [contact: [200]], legacySharesBobsKey: legacySharesKey)
        let trustGuard = harness.omemoService.trustGuard(forAccountJID: testJIDString)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        module.configureTrustGuard(trustGuard)
        let keys = try [OMEMOWireFormat.omemo2: harness.bob, .legacy: #require(harness.legacyKeys[200])]
        let fingerprints = try Dictionary(uniqueKeysWithValues: keys.map { try ($0.key, storedFingerprint(of: $0.value, format: $0.key)) })
        let held = try #require(fingerprints[heldVersion])
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: held, trustLevel: .trusted
        ))
        let otherVersion: OMEMOWireFormat = heldVersion == .omemo2 ? .legacy : .omemo2
        let rebuiltVersions: Set<OMEMOWireFormat> = legacySharesKey ? [.omemo2, .legacy] : [heldVersion]

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        let outcome: OMEMOSessionResetReport.Device.Outcome = try legacySharesKey
            ? .rebuilt(needsTrusting: false)
            : .rebuiltKeyRefused(needsTrusting: false, newFingerprint: #require(fingerprints[otherVersion]))
        #expect(report.devices == [.init(deviceID: 200, outcome: outcome)])
        let detail = try await notes(in: harness).first?.detail
        if legacySharesKey {
            #expect(detail == nil)
        } else {
            let refusedKey = try displayedCurveKey(of: #require(keys[otherVersion]))
            #expect(detail == "Device 200 has a new session. It also offered a different key (\(refusedKey)), which Ducko refused")
        }
        #expect(trustGuard.heldFingerprint(peer: contact, deviceID: 200) == held)
        #expect(!trustGuard.refuses(OMEMODeviceKey(jid: contact, deviceID: 200)))
        let rows = try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString)
        #expect(rows.map { "\($0.deviceID) \($0.fingerprint) \($0.trustLevel)" } == ["200 \(held) trusted"])
        let sessions = try await harness.omemoStore.loadSessions(for: testJIDString)
        #expect(Set(sessions.map(\.version)) == rebuiltVersions)
        for version in rebuiltVersions {
            #expect(try await answerReadAfterRestart(in: harness, version: version, from: #require(keys[version])) == "answer \(version)")
        }
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// With no key held and no session, the first version's bundle names the known key, so the other version's key is
    /// refused beside the new session and the first is held.
    @Test func `A reset of a device on both lists with no key held rebuilds the OMEMO 2 version and refuses the legacy one's other key`() async throws {
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [contact: [200]])
        let service = try await guardedService(in: harness)
        let trustGuard = service.trustGuard(forAccountJID: testJIDString)
        let omemo2Key = try storedFingerprint(of: harness.bob, format: .omemo2)
        let legacyKey = try storedFingerprint(of: #require(harness.legacyKeys[200]), format: .legacy)

        let report = try await service.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .rebuiltKeyRefused(needsTrusting: false, newFingerprint: legacyKey))])
        #expect(trustGuard.heldFingerprint(peer: contact, deviceID: 200) == omemo2Key)
        #expect(try await harness.omemoStore.loadSessions(for: testJIDString).map(\.version) == [.omemo2])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A bundle that lists no pre-key still names the device's key, so another key the other version offers replaces
    /// nothing.
    @Test func `A reset of a device whose bundle carrying the held key lists no pre-key keeps the held key while the other version offers another`() async throws {
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [contact: [200]], legacyBundlesWithoutPreKeys: [200])
        let service = try await guardedService(in: harness)
        let trustGuard = service.trustGuard(forAccountJID: testJIDString)
        let held = try storedFingerprint(of: #require(harness.legacyKeys[200]), format: .legacy)
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: held, trustLevel: .verified
        ))

        let report = try await service.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .noBundle)])
        #expect(trustGuard.heldFingerprint(peer: contact, deviceID: 200) == held)
        #expect(!trustGuard.refuses(OMEMODeviceKey(jid: contact, deviceID: 200)))
        let rows = try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString)
        #expect(rows.map { "\($0.deviceID) \($0.fingerprint) \($0.trustLevel)" } == ["200 \(held) verified"])
        #expect(try await harness.omemoStore.loadSessions(for: testJIDString).isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// With no key held, the discarded legacy session is the only record of the device's key. The legacy bundle still
    /// carries that key but lists no pre-key, while the OMEMO 2 bundle offers another key.
    @Test func `A reset that discards the only record of a device's key holds and stores the key, so another key stays refused`() async throws {
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [contact: [200]], legacyBundlesWithoutPreKeys: [200])
        let service = try await guardedService(in: harness)
        let trustGuard = service.trustGuard(forAccountJID: testJIDString)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        let legacyKeys = try #require(harness.legacyKeys[200])
        let known = try storedFingerprint(of: legacyKeys, format: .legacy)
        let session = try legacySession(with: legacyKeys, in: harness)
        module.restoreSessions([session])
        try await harness.omemoStore.saveSession(OMEMOStoredSession(accountJID: testJIDString, entry: session))
        try #require(trustGuard.heldFingerprint(peer: contact, deviceID: 200).isEmpty)

        let report = try await service.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .noBundle)])
        #expect(trustGuard.heldFingerprint(peer: contact, deviceID: 200) == known)
        let rows = try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString)
        #expect(rows.map { "\($0.deviceID) \($0.fingerprint) \($0.trustLevel)" } == ["200 \(known) trusted"])
        #expect(try await harness.omemoStore.loadSessions(for: testJIDString).isEmpty)
        let otherBundle = try await module.fetchBundle(from: contact, deviceID: 200, version: .omemo2)
        #expect(throws: OMEMOModuleError.changedIdentityKey) {
            try module.establishSession(
                sessionKey: SessionKey(jid: contact, deviceID: 200, version: .omemo2), identity: module.requireOwnIdentity(), bundle: otherBundle
            )
        }
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A disconnect drops the module's sessions, the OMEMO 2 one a message built and a restored legacy one, while the
    /// reset's bundle request is held. The request then fails, or is answered after all.
    @Test(arguments: [false, true])
    func `A reset whose bundle request outlasts a disconnect leaves the stored sessions as they were`(isAnswered: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [contact: [200]], legacySharesBobsKey: true)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try await harness.chatService.sendMessage(to: contact, body: "secret", accountID: harness.accountID)
        try module.restoreSessions([legacySession(with: harness.bob, in: harness)])
        await harness.omemoService.saveModuleSessions(module: module, accountID: harness.accountID)
        let stored = try await harness.omemoStore.loadSessions(for: testJIDString).map { "\($0.version) \(Array($0.sessionData))" }
        try #require(stored.count == 2)
        await harness.transport.blockSends { $0.hasPrefix("<iq") && $0.contains(XMPPNamespaces.omemoBundles) }
        let reset = Task { try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID) }
        try #require(await boundedOutcome { await harness.transport.waitForBlockedSend() } != nil)

        await module.handleDisconnect()
        if isAnswered {
            await harness.transport.releaseBlockedSends()
        } else {
            await harness.transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))
        }

        try #require(await boundedOutcome { _ = try await reset.value } != nil)
        let outcome = try await reset.value.devices.first?.outcome
        if case .failed? = outcome {} else { Issue.record("Expected the reset to fail, got \(String(describing: outcome))") }
        let after = try await harness.omemoStore.loadSessions(for: testJIDString).map { "\($0.version) \(Array($0.sessionData))" }
        #expect(Set(after) == Set(stored))
        #expect(try await answerReadAfterRestart(in: harness, version: .omemo2, from: harness.bob) == "answer omemo2")
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// OMEMO 2 is rebuilt first. The device is marked untrusted while its empty message is held, so no legacy session can
    /// be built.
    @Test func `A reset that rebuilds one version and fails the next saves the new session, deletes the other one, and keeps every other session`() async throws {
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [contact: [200]], legacySharesBobsKey: true)
        let service = try await guardedService(in: harness)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try await harness.omemoStore.saveSession(storedSession(1))
        try await harness.omemoStore.saveSession(OMEMOStoredSession(
            accountJID: testJIDString, peerJID: contact.description, peerDeviceID: 200, version: .legacy, sessionData: Data([2]), associatedData: Data([2])
        ))
        try await harness.omemoStore.saveSession(storedSession(3, deviceID: 300))
        await harness.transport.blockSends { $0.hasPrefix("<message") && $0.contains("<encrypted") && !$0.contains(XMPPNamespaces.omemoLegacy) }
        let reset = Task { try await service.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID) }
        try #require(await boundedOutcome { await harness.transport.waitForBlockedSend() } != nil)

        _ = service.trustGuard(forAccountJID: testJIDString).applyDistrust(peer: contact, deviceID: 200)
        await harness.transport.releaseBlockedSends()

        try #require(await boundedOutcome { _ = try await reset.value } != nil)
        #expect(try await reset.value.devices == [.init(deviceID: 200, outcome: .failed(OMEMOModuleError.untrustedDevice.localizedDescription))])
        let rebuilt = try #require(module.exportSession(jid: contact, deviceID: 200, version: .omemo2))
        let stored = try await harness.omemoStore.loadSessions(for: testJIDString)
        #expect(Set(stored.map { "\($0.peerDeviceID) \($0.version) \(Array($0.sessionData))" }) == ["200 omemo2 \(rebuilt.sessionData)", "300 omemo2 [3]"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The device is marked untrusted. Its OMEMO 2 bundle carries the held key, and its legacy bundle another one.
    @Test func `A reset of a device marked untrusted that offers another key in one version only discards its sessions and keeps the held key`() async throws {
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [contact: [200]])
        let service = try await guardedService(in: harness)
        let trustGuard = service.trustGuard(forAccountJID: testJIDString)
        let held = try storedFingerprint(of: harness.bob, format: .omemo2)
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: held, trustLevel: .untrusted
        ))

        let report = try await service.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .discarded)])
        #expect(trustGuard.heldFingerprint(peer: contact, deviceID: 200) == held)
        let rows = try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString)
        #expect(rows.map { "\($0.deviceID) \($0.fingerprint) \($0.trustLevel)" } == ["200 \(held) untrusted"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// OMEMO 2 is rebuilt, while the legacy bundle lists no pre-key. The connection ends while the OMEMO 2 empty
    /// message is held.
    @Test func `A reset whose empty message outlasts a disconnect leaves the stored sessions as they were`() async throws {
        let harness = try await EncryptedSendHarness.connect(
            legacyDeviceLists: [contact: [200]], legacyBundlesWithoutPreKeys: [200], legacySharesBobsKey: true
        )
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try await harness.omemoStore.saveSession(storedSession(1))
        try await harness.omemoStore.saveSession(OMEMOStoredSession(
            accountJID: testJIDString, peerJID: contact.description, peerDeviceID: 200, version: .legacy, sessionData: Data([2]), associatedData: Data([2])
        ))
        await harness.transport.blockSends { $0.hasPrefix("<message") && $0.contains("<encrypted") }
        let reset = Task { try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID) }
        try #require(await boundedOutcome { await harness.transport.waitForBlockedSend() } != nil)

        await module.handleDisconnect()
        await harness.transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))

        try #require(await boundedOutcome { _ = try await reset.value } != nil)
        let outcome = try await reset.value.devices.first?.outcome
        if case .failed? = outcome {} else { Issue.record("Expected the reset to fail, got \(String(describing: outcome))") }
        let stored = try await harness.omemoStore.loadSessions(for: testJIDString)
        #expect(Set(stored.map { "\($0.version) \(Array($0.sessionData))" }) == ["omemo2 [1]", "legacy [2]"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Both versions carry bob's key, and OMEMO 2 is rebuilt first. The connection ends while its empty message is held.
    @Test func `A reset whose connection ends during one version's empty message builds no session in the next`() async throws {
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [contact: [200]], legacySharesBobsKey: true)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        await harness.transport.blockSends { $0.hasPrefix("<message") && $0.contains("<encrypted") }
        let reset = Task { try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID) }
        try #require(await boundedOutcome { await harness.transport.waitForBlockedSend() } != nil)

        await module.handleDisconnect()
        await harness.transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))

        try #require(await boundedOutcome { _ = try await reset.value } != nil)
        #expect(module.allSessionEntries().isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The device is on the OMEMO 2 list only, so the reset would rebuild that version and discard the legacy one.
    @Test func `A reset whose known key cannot be stored fails the device and keeps its stored sessions`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await harness.omemoStore.saveSession(storedSession(1))
        try await harness.omemoStore.saveSession(OMEMOStoredSession(
            accountJID: testJIDString, peerJID: contact.description, peerDeviceID: 200, version: .legacy, sessionData: Data([2]), associatedData: Data([3])
        ))
        await harness.omemoStore.setFailing(.fillTrustFingerprint)

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        let outcome = report.devices.first?.outcome
        if case .failed? = outcome {} else { Issue.record("Expected the reset to fail, got \(String(describing: outcome))") }
        let stored = try await harness.omemoStore.loadSessions(for: testJIDString).map {
            "\($0.peerDeviceID) \($0.version) \(Array($0.sessionData)) \(Array($0.associatedData))"
        }
        #expect(stored.filter { $0.contains("omemo2") } == ["200 omemo2 [1] [1]"])
        #expect(stored.filter { $0.contains("legacy") } == ["200 legacy [2] [3]"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// OMEMO 2 is rebuilt, while the legacy bundle lists no pre-key. The connection ends as the new OMEMO 2 session is
    /// saved.
    @Test func `A reset whose connection ends while it saves one version's session keeps the stored session of the next`() async throws {
        let harness = try await EncryptedSendHarness.connect(
            legacyDeviceLists: [contact: [200]], legacyBundlesWithoutPreKeys: [200], legacySharesBobsKey: true
        )
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try await harness.omemoStore.saveSession(OMEMOStoredSession(
            accountJID: testJIDString, peerJID: contact.description, peerDeviceID: 200, version: .legacy, sessionData: Data([2]), associatedData: Data([2])
        ))
        await harness.omemoStore.setBeforeSessionSave { await module.handleDisconnect() }

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        try #require(module.ownDeviceID == nil)
        #expect(report.devices == [.init(deviceID: 200, outcome: .failed(OMEMOModuleError.notSetUp.localizedDescription))])
        let stored = try await harness.omemoStore.loadSessions(for: testJIDString).filter { $0.version == .legacy }
        #expect(stored.map { Array($0.sessionData) } == [[2]])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The device's trust row names no key yet. The connection ends while the reset's empty message is held.
    @Test func `A reset whose connection ends during its empty message stores no key for the device`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        let before = try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString)
        try #require(before.map { "\($0.deviceID) \($0.fingerprint) \($0.trustLevel)" } == ["200  trusted"])
        await harness.transport.blockSends { $0.hasPrefix("<message") && $0.contains("<encrypted") }
        let reset = Task { try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID) }
        try #require(await boundedOutcome { await harness.transport.waitForBlockedSend() } != nil)

        await module.handleDisconnect()
        await harness.transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))

        try #require(await boundedOutcome { _ = try await reset.value } != nil)
        #expect(try await reset.value.devices == [.init(deviceID: 200, outcome: .failed(OMEMOModuleError.notSetUp.localizedDescription))])
        let rows = try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString)
        #expect(rows.map { "\($0.deviceID) \($0.fingerprint) \($0.trustLevel)" } == ["200  trusted"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The legacy bundle lists no pre-key, so only OMEMO 2 is rebuilt. While its empty message is held, a key exchange
    /// from the device installs and saves a legacy session.
    @Test func `A reset keeps the stored session of a version a key exchange gave a session again meanwhile`() async throws {
        let harness = try await EncryptedSendHarness.connect(
            legacyDeviceLists: [contact: [200]], legacyBundlesWithoutPreKeys: [200], legacySharesBobsKey: true
        )
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try await harness.omemoStore.saveSession(OMEMOStoredSession(
            accountJID: testJIDString, peerJID: contact.description, peerDeviceID: 200, version: .legacy, sessionData: Data([2]), associatedData: Data([2])
        ))
        await harness.transport.blockSends { $0.hasPrefix("<message") && $0.contains("<encrypted") }
        let reset = Task { try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID) }
        try #require(await boundedOutcome { await harness.transport.waitForBlockedSend() } != nil)

        let fresh = try legacySession(with: harness.bob, in: harness)
        module.restoreSessions([fresh])
        try await harness.omemoStore.saveSession(OMEMOStoredSession(accountJID: testJIDString, entry: fresh))
        await harness.transport.releaseBlockedSends()

        try #require(await boundedOutcome { _ = try await reset.value } != nil)
        #expect(try await reset.value.devices == [.init(deviceID: 200, outcome: .rebuilt(needsTrusting: false))])
        let stored = try await harness.omemoStore.loadSessions(for: testJIDString).filter { $0.version == .legacy }
        #expect(stored.map { Array($0.sessionData) } == [fresh.sessionData])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset fetches the device lists afresh, so it resets the device listed now and leaves out one no longer listed`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        module.state.withLock { $0.deviceLists[.omemo2, default: [:]][contact] = [777] }
        try #require(try await module.fetchListedDevices(of: contact) == [777])

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .rebuilt(needsTrusting: false))])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset acts once on a device that each of its lists names twice`() async throws {
        let harness = try await EncryptedSendHarness.connect(contactDevices: [200, 200], legacyDeviceLists: [contact: [200, 200]], legacySharesBobsKey: true)

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .rebuilt(needsTrusting: false))])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset that rebuilds one version deletes the stored session of the version it could not rebuild`() async throws {
        let harness = try await EncryptedSendHarness.connect(
            legacyDeviceLists: [contact: [200]], legacyBundlesWithoutPreKeys: [200], legacySharesBobsKey: true
        )
        try await harness.omemoStore.saveSession(OMEMOStoredSession(
            accountJID: testJIDString, peerJID: contact.description, peerDeviceID: 200, version: .legacy,
            sessionData: Data(storedSessionData(format: .legacy)), associatedData: Data(storedAssociatedData(format: .legacy))
        ))
        try #require(try await harness.omemoStore.loadSessions(for: testJIDString).map(\.version) == [.legacy])

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .rebuilt(needsTrusting: false))])
        #expect(try await harness.omemoStore.loadSessions(for: testJIDString).map(\.version) == [.omemo2])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The versions are reset OMEMO 2 first, and its empty message is the one that fails.
    @Test func `A reset whose empty message fails in one version still rebuilds the other, and stores the device's sessions as they are`() async throws {
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [contact: [200]], legacySharesBobsKey: true)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try await harness.omemoStore.saveSession(storedSession(1))
        let failure = XMPPClientError.sendFailed("The connection was closed")
        await harness.transport.failNextSend(matching: "<encrypted", error: failure)

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .failed(failure.localizedDescription))])
        #expect(await harness.transport.sentBytes.contains {
            let stanza = String(decoding: $0, as: UTF8.self)
            return stanza.hasPrefix("<message") && stanza.contains(XMPPNamespaces.omemoLegacy)
        })
        let stored = try await harness.omemoStore.loadSessions(for: testJIDString)
        let held = module.allSessionEntries().filter { $0.jid == contact && $0.deviceID == 200 }
        #expect(Set(held.map(\.version)) == [.omemo2, .legacy])
        #expect(Set(stored.map { "\($0.version) \(Array($0.sessionData))" }) == Set(held.map { "\($0.version) \($0.sessionData)" }))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Like the other session saves, the reset's is best-effort: a failed save does not fail the reset.
    @Test func `A reset whose new session cannot be saved still reports it`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        await harness.omemoStore.setFailing(.saveSession)

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .rebuilt(needsTrusting: false))])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A rebuilt device that is not trusted for encryption is reported and noted as needing trusting`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let service = try await guardedService(trustOnFirstUse: false, in: harness)
        try await harness.omemoStore.saveTrust(OMEMOTrust(accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: "", trustLevel: .undecided))

        let report = try await service.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .rebuilt(needsTrusting: true))])
        let detail = try #require(await notes(in: harness).first?.detail)
        #expect(detail.contains("needs trusting"))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset takes in an untrust another process stored, and only discards the device's session`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let service = try await guardedService(in: harness)
        try await harness.omemoStore.saveTrust(OMEMOTrust(accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: "", trustLevel: .untrusted))
        try await harness.omemoStore.saveSession(storedSession(1))

        let report = try await service.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .discarded)])
        #expect(try await harness.omemoStore.loadSessions(for: testJIDString).isEmpty)
        #expect(await !sentEncrypted(in: harness))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset naming a device that is not on the list only deletes its stored session and sends it nothing`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await harness.omemoStore.saveSession(storedSession(1, deviceID: 999))

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: 999, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 999, outcome: .notListed)])
        #expect(try await harness.omemoStore.loadSessions(for: testJIDString).isEmpty)
        #expect(await !sentEncrypted(in: harness))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset naming a device that is not on the list drops the module's sessions in every version, so a later save does not store them again`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try await harness.chatService.sendMessage(to: contact, body: "secret", accountID: harness.accountID)
        let bobsSession = try #require(module.exportSession(jid: contact, deviceID: 200, version: .omemo2))
        try module.restoreSessions([
            OMEMOModule.StoredSessionEntry(
                jid: contact, deviceID: 999, version: .omemo2, sessionData: bobsSession.sessionData, associatedData: bobsSession.associatedData
            ),
            OMEMOModule.StoredSessionEntry(
                jid: contact, deviceID: 999, version: .legacy, sessionData: storedSessionData(format: .legacy), associatedData: storedAssociatedData(format: .legacy)
            )
        ])
        try #require(module.allSessionEntries().count { $0.jid == contact && $0.deviceID == 999 } == 2)
        try await harness.omemoStore.saveSession(storedSession(1, deviceID: 999))

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: 999, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 999, outcome: .notListed)])
        #expect(!module.allSessionEntries().contains { $0.jid == contact && $0.deviceID == 999 })
        await harness.omemoService.saveModuleSessions(module: module, accountID: harness.accountID)
        #expect(try await !harness.omemoStore.loadSessions(for: testJIDString).contains { $0.peerDeviceID == 999 })
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// With no key held, the discarded session is the only record of the device's key.
    @Test func `A reset naming a device that is not on the list holds and stores the key of the session it discards`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let service = try await guardedService(in: harness)
        let trustGuard = service.trustGuard(forAccountJID: testJIDString)
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try module.restoreSessions([legacySession(with: harness.bob, deviceID: 999, in: harness)])
        let known = try storedFingerprint(of: harness.bob, format: .legacy)
        try #require(trustGuard.heldFingerprint(peer: contact, deviceID: 999).isEmpty)

        let report = try await service.resetSessions(peerJID: contact.description, deviceID: 999, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 999, outcome: .notListed)])
        #expect(trustGuard.heldFingerprint(peer: contact, deviceID: 999) == known)
        let rows = try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString).filter { $0.deviceID == 999 }
        #expect(rows.map { "\($0.fingerprint) \($0.trustLevel)" } == ["\(known) undecided"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The connection ends while the reset fetches the device lists.
    @Test func `A reset naming a device that is not on the list whose connection ends meanwhile keeps its stored sessions`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        let session = try legacySession(with: harness.bob, deviceID: 999, in: harness)
        module.restoreSessions([session])
        try await harness.omemoStore.saveSession(OMEMOStoredSession(accountJID: testJIDString, entry: session))
        try await harness.omemoStore.saveSession(storedSession(1, deviceID: 999))
        let before = try await harness.omemoStore.loadSessions(for: testJIDString).map { "\($0.version) \(Array($0.sessionData))" }
        try #require(before.count == 2)
        await harness.transport.blockSends {
            $0.hasPrefix("<iq") && $0.contains("to=\"\(contact)\"") && $0.contains("<items node=\"\(XMPPNamespaces.omemoDevices)\"")
        }
        let reset = Task { try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: 999, accountID: harness.accountID) }
        try #require(await boundedOutcome { await harness.transport.waitForBlockedSend() } != nil)

        await module.handleDisconnect()
        await harness.transport.releaseBlockedSends()

        try #require(await boundedOutcome { _ = try await reset.value } != nil)
        let outcome = try await reset.value.devices.first?.outcome
        if case .failed? = outcome {} else { Issue.record("Expected the reset to fail, got \(String(describing: outcome))") }
        let after = try await harness.omemoStore.loadSessions(for: testJIDString).map { "\($0.version) \(Array($0.sessionData))" }
        #expect(Set(after) == Set(before))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A key exchange from the device installs and saves a legacy session while the reset stores the device's key.
    @Test func `A reset naming a device that is not on the list keeps a session a key exchange saved meanwhile`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try module.restoreSessions([legacySession(with: harness.bob, deviceID: 999, in: harness)])
        try await harness.omemoStore.saveSession(storedSession(1, deviceID: 999))
        let fresh = try legacySession(with: harness.bob, deviceID: 999, in: harness)
        let store = harness.omemoStore
        await store.setBeforeTrustFill {
            module.restoreSessions([fresh])
            try? await store.saveSession(OMEMOStoredSession(accountJID: testJIDString, entry: fresh))
        }

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: 999, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 999, outcome: .notListed)])
        let stored = try await harness.omemoStore.loadSessions(for: testJIDString)
        #expect(stored.map { "\($0.version) \(Array($0.sessionData))" } == ["legacy \(fresh.sessionData)"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Another process stores another key for the device while the reset stores the key of the session it discards.
    @Test func `A reset whose device's stored row names another key fails the device and keeps its stored session`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        try module.restoreSessions([legacySession(with: harness.bob, deviceID: 999, in: harness)])
        try await harness.omemoStore.saveSession(storedSession(1, deviceID: 999))
        let other = String(repeating: "ab", count: 32)
        let store = harness.omemoStore
        await store.setBeforeTrustFill {
            try? await store.saveTrust(OMEMOTrust(accountJID: testJIDString, peerJID: contact.description, deviceID: 999, fingerprint: other, trustLevel: .verified))
        }

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: 999, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 999, outcome: .failed(OMEMOServiceError.conflictingFingerprints.localizedDescription))])
        let stored = try await harness.omemoStore.loadSessions(for: testJIDString)
        #expect(stored.map { "\($0.peerDeviceID) \($0.version) \(Array($0.sessionData))" } == ["999 omemo2 [1]"])
        let rows = try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString).filter { $0.deviceID == 999 }
        #expect(rows.map { "\($0.fingerprint) \($0.trustLevel)" } == ["\(other) verified"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A device whose reset fails is reported as failed, and the note says so`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let failure = XMPPClientError.sendFailed("The connection was closed")
        await harness.transport.failNextSend(matching: "<encrypted", error: failure)

        let report = try await harness.omemoService.resetSessions(peerJID: contact.description, deviceID: nil, accountID: harness.accountID)

        #expect(report.devices == [.init(deviceID: 200, outcome: .failed(failure.localizedDescription))])
        let detail = try #require(await notes(in: harness).first?.detail)
        #expect(detail.contains("could not be reset"))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset of the account's own devices rebuilds the session with each other device, leaves this one out, and notes nothing`() async throws {
        let harness = try await EncryptedSendHarness.connect(otherOwnDevices: [300])
        try await harness.omemoStore.saveTrust(OMEMOTrust(accountJID: testJIDString, peerJID: testJIDString, deviceID: 300, fingerprint: "", trustLevel: .trusted))

        let report = try await harness.omemoService.resetSessions(peerJID: testJIDString, deviceID: nil, accountID: harness.accountID)

        #expect(report == OMEMOSessionResetReport(peerJID: testJIDString, devices: [.init(deviceID: 300, outcome: .rebuilt(needsTrusting: false))]))
        let sent = await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }
        #expect(sent?.contains("to=\"\(testJIDString)\"") == true)
        let sessions = try await harness.omemoStore.loadSessions(for: testJIDString)
        #expect(sessions.map { "\($0.peerJID) \($0.peerDeviceID)" } == ["\(testJIDString) 300"])
        #expect(await harness.transcripts.notes.isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `A reset naming this device is refused`() async throws {
        let harness = try await EncryptedSendHarness.connect(otherOwnDevices: [300])

        let error = await #expect(throws: OMEMOServiceError.self) {
            _ = try await harness.omemoService.resetSessions(peerJID: testJIDString, deviceID: 100, accountID: harness.accountID)
        }

        if case .thisDeviceNotResettable? = error {} else { Issue.record("Expected this device to be refused, got \(String(describing: error))") }
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}
