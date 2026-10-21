// Split candidate.
// swiftlint:disable file_length
import CryptoKit
import DuckoTestSupport
import Testing
@testable import DuckoXMPP

enum OMEMOModuleTests { // swiftlint:disable:this type_body_length
    // MARK: - Features

    struct Features {
        @Test func `advertises OMEMO and EME`() {
            let pepModule = PEPModule()
            let module = OMEMOModule(pepModule: pepModule)
            #expect(module.features.contains(XMPPNamespaces.omemo))
            #expect(module.features.contains(XMPPNamespaces.eme))
        }
    }

    // MARK: - Device List XML

    struct DeviceListTests {
        @Test func `parses device list XML`() {
            let xml = XMLElement(
                name: "devices", namespace: XMPPNamespaces.omemo,
                children: [
                    .element(XMLElement(name: "device", attributes: ["id": "12345"])),
                    .element(XMLElement(name: "device", attributes: ["id": "67890"]))
                ]
            )
            let module = makeModule()
            let devices = module.parseDeviceList(xml)
            #expect(devices == [12345, 67890])
        }

        @Test func `parses empty device list`() {
            let xml = XMLElement(name: "devices", namespace: XMPPNamespaces.omemo)
            let module = makeModule()
            let devices = module.parseDeviceList(xml)
            #expect(devices.isEmpty)
        }

        @Test func `skips invalid device I ds`() {
            let xml = XMLElement(
                name: "devices", namespace: XMPPNamespaces.omemo,
                children: [
                    .element(XMLElement(name: "device", attributes: ["id": "123"])),
                    .element(XMLElement(name: "device", attributes: ["id": "notanumber"])),
                    .element(XMLElement(name: "device"))
                ]
            )
            let module = makeModule()
            let devices = module.parseDeviceList(xml)
            #expect(devices == [123])
        }
    }

    // MARK: - Bundle XML

    struct BundleTests {
        @Test func `round trips bundle XML`() throws {
            let bundle = makeTestBundle()
            let module = makeModule()
            let xml = module.buildBundleElement(bundle)
            let parsed = try #require(
                module.parseBundleElement(xml, deviceID: 42)
            )
            #expect(parsed.deviceID.value == 42)
            #expect(parsed.identityKey == bundle.identityKey)
            #expect(parsed.signedPreKey == bundle.signedPreKey)
            #expect(parsed.signedPreKeyID == bundle.signedPreKeyID)
            #expect(parsed.signedPreKeySignature == bundle.signedPreKeySignature)
            let parsedPKCount = parsed.preKeys.count
            #expect(parsedPKCount == bundle.preKeys.count)
            for (original, parsed) in zip(bundle.preKeys, parsed.preKeys) {
                #expect(original.id == parsed.id)
                #expect(original.publicKey == parsed.publicKey)
            }
        }

        @Test func `parses minimal bundle`() {
            let module = makeModule()
            // Missing prekeys element
            let xml = XMLElement(name: "bundle", namespace: XMPPNamespaces.omemo)
            let result = module.parseBundleElement(xml, deviceID: 1)
            #expect(result == nil)
        }
    }

    // MARK: - Encrypted Element Building

    struct EncryptedElementTests {
        @Test func `builds encrypted element`() {
            let module = makeModule()
            let key1 = XMLElement(name: "key", attributes: ["rid": "100"])
            let key2 = XMLElement(name: "key", attributes: ["rid": "200", "kex": "true"])
            let key3 = XMLElement(name: "key", attributes: ["rid": "300"])
            let encrypted = module.buildEncryptedElement(
                keys: [(peerJID, key1), (ownJID, key2), (peerJID, key3)],
                payload: "encryptedpayload",
                senderDeviceID: 42
            )
            #expect(encrypted.namespace == XMPPNamespaces.omemo)
            let header = encrypted.child(named: "header")
            #expect(header?.attribute("sid") == "42")
            let keys = header?.children(named: "keys") ?? []
            #expect(keys.map { $0.attribute("jid") } == [peerJID.description, ownJID.description])
            #expect(keys.map { $0.children(named: "key").compactMap { $0.attribute("rid") } } == [["100", "300"], ["200"]])
            let payloadEl = encrypted.child(named: "payload")
            #expect(payloadEl?.textContent == "encryptedpayload")
        }
    }

    // MARK: - End-to-End Encrypt/Decrypt

    struct EndToEndTests {
        @Test func `encrypt and decrypt content key`() throws {
            // Simulate: Alice encrypts a content key for Bob using
            // X3DH + Double Ratchet, then Bob decrypts it.
            let aliceIdentity = OMEMOIdentityKeyPair()
            let bobIdentity = OMEMOIdentityKeyPair()
            let bobSignedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(
                keyID: 1, identityKey: bobIdentity
            )
            let bobPreKey = OMEMOPreKey(keyID: 1)
            let bobBundle = OMEMOPreKeyManager.buildBundle(
                deviceID: OMEMODeviceID(value: 200),
                identityKeyPair: bobIdentity,
                signedPreKey: bobSignedPreKey,
                preKeys: [bobPreKey]
            )
            let peerBundle = OMEMOX3DHPeerBundle(
                identityKey: bobBundle.identityKey,
                signedPreKey: bobBundle.signedPreKey,
                signedPreKeySignature: bobBundle.signedPreKeySignature,
                oneTimePreKey: bobBundle.preKeys.first?.publicKey
            )
            let aliceX3DH = try OMEMOX3DH.initiatorKeyAgreement(
                identityKeyPair: aliceIdentity,
                peerBundle: peerBundle
            )
            var aliceSession = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: aliceX3DH.sharedSecret,
                peerSignedPreKey: bobBundle.signedPreKey
            )
            let contentKey: [UInt8] = (0 ..< 32).map { _ in
                UInt8.random(in: 0 ... 255)
            }
            let ratchetMessage = try aliceSession.encrypt(
                plaintext: contentKey,
                associatedData: aliceX3DH.associatedData
            )
            // Bob receives and decrypts
            let bobX3DH = try OMEMOX3DH.responderKeyAgreement(
                identityKeyPair: bobIdentity,
                signedPreKey: bobSignedPreKey,
                oneTimePreKey: bobPreKey,
                peerIdentityKey: aliceIdentity.publicKeyBytes,
                peerEphemeralKey: aliceX3DH.ephemeralPublicKey
            )
            var bobSession = OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: bobX3DH.sharedSecret,
                ourSignedPreKeyPair: bobSignedPreKey.keyPair
            )
            let decrypted = try bobSession.decrypt(
                message: ratchetMessage,
                associatedData: bobX3DH.associatedData
            )
            #expect(decrypted == contentKey)
        }
    }

    // MARK: - Connect-Time Branches

    struct DeviceListFetchTests {
        @Test func `Cache miss issues PEP retrieve`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            let task = Task { try await omemoModule.fetchDeviceList(for: peerJID) }

            await mock.waitForSent(count: 1)
            let iqID = try await #require(extractIQID(from: mock.sentBytes[0]))
            await mock.simulateReceive(makeDeviceListResultIQ(iqID: iqID, fromJID: peerJID, devices: [42, 43]))

            let devices = try await task.value
            #expect(devices == [42, 43])

            await disconnectFast(client)
        }

        @Test func `Cache hit returns without IQ`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            // Prime the cache via the cache-miss flow.
            let primeTask = Task { try await omemoModule.fetchDeviceList(for: peerJID) }
            await mock.waitForSent(count: 1)
            let primeID = try await #require(extractIQID(from: mock.sentBytes[0]))
            await mock.simulateReceive(makeDeviceListResultIQ(iqID: primeID, fromJID: peerJID, devices: [42]))
            _ = try await primeTask.value

            let baseline = await mock.sentBytes.count

            // Second fetch (no force) should hit cache and NOT send an IQ.
            let cached = try await omemoModule.fetchDeviceList(for: peerJID)
            #expect(cached == [42])

            let after = await mock.sentBytes.count
            #expect(after == baseline)

            await disconnectFast(client)
        }

        @Test func `Force refresh emits omemoDeviceListReceived`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            // Prime the cache so the upcoming call is a forced refresh, not a
            // cache miss (cache miss without force does NOT emit an event).
            let primeTask = Task { try await omemoModule.fetchDeviceList(for: peerJID) }
            await mock.waitForSent(count: 1)
            let primeID = try await #require(extractIQID(from: mock.sentBytes[0]))
            await mock.simulateReceive(makeDeviceListResultIQ(iqID: primeID, fromJID: peerJID, devices: [42]))
            _ = try await primeTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .omemoDeviceListReceived = event { return true }
                    return false
                }
            }

            let refreshTask = Task { try await omemoModule.fetchDeviceList(for: peerJID, forceRefresh: true) }
            await mock.waitForSent(count: 2)
            let refreshID = try await #require(extractIQID(from: mock.sentBytes[1]))
            await mock.simulateReceive(makeDeviceListResultIQ(iqID: refreshID, fromJID: peerJID, devices: [42, 99]))

            _ = try await refreshTask.value
            let collected = try await eventsTask.value
            guard case let .omemoDeviceListReceived(jid, devices) = try #require(collected.last) else {
                Issue.record("Expected omemoDeviceListReceived event")
                return
            }
            #expect(jid == peerJID)
            #expect(devices == [42, 99])

            await disconnectFast(client)
        }
    }

    struct EncryptKeysInParallelTests {
        @Test func `Skip device returning item-not-found yields single key`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            let task = Task {
                try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: [10, 11], ownDeviceIDs: []
                )
            }

            await mock.waitForSent(count: 2)
            let sent = await mock.sentBytes
            let id1 = try #require(extractIQID(from: sent[0]))
            let id2 = try #require(extractIQID(from: sent[1]))
            let dev2 = try #require(extractBundleDeviceID(from: sent[1]))

            // First fetch fails with item-not-found; second returns a valid bundle.
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: id1, fromJID: peerJID))
            let validBundleIQ = try makeValidBundleResultIQ(
                iqID: id2, deviceID: dev2, fromJID: peerJID, module: omemoModule
            )
            await mock.simulateReceive(validBundleIQ)

            let elements = try await task.value
            let header = elements.encrypted.child(named: "header")
            let keys = header?.child(named: "keys")?.children(named: "key") ?? []
            #expect(keys.count == 1)
            #expect(keys.first?.attribute("rid") == "\(dev2)")

            await disconnectFast(client)
        }
    }

    struct NoUsableRecipientDevicesTests {
        @Test func `Empty recipient list throws`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) {
                _ = try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: [], ownDeviceIDs: []
                )
            }

            await disconnectFast(client)
        }

        @Test func `All recipients item-not-found throws`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            let task = Task {
                try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: [10, 11], ownDeviceIDs: []
                )
            }

            await mock.waitForSent(count: 2)
            let sent = await mock.sentBytes
            let id1 = try #require(extractIQID(from: sent[0]))
            let id2 = try #require(extractIQID(from: sent[1]))
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: id1, fromJID: peerJID))
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: id2, fromJID: peerJID))

            await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) {
                _ = try await task.value
            }

            await disconnectFast(client)
        }

        /// Locks the emit-before-throw contract: `omemoRecipientsPartial`
        /// fires with the dropped peer devices BEFORE
        /// `noUsableRecipientDevices` is thrown, so operators get the same
        /// diagnostic in the worst case as in partial-coverage cases. A
        /// regression that flipped the order would silently hide the
        /// dropped set in the most-needed scenario.
        @Test func `omemoRecipientsPartial fires before noUsableRecipientDevices throw`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .omemoRecipientsPartial = event { return true }
                    return false
                }
            }

            let task = Task {
                try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: [10, 11], ownDeviceIDs: []
                )
            }

            await mock.waitForSent(count: 2)
            let sent = await mock.sentBytes
            let id1 = try #require(extractIQID(from: sent[0]))
            let id2 = try #require(extractIQID(from: sent[1]))
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: id1, fromJID: peerJID))
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: id2, fromJID: peerJID))

            await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) {
                _ = try await task.value
            }

            // The throw must NOT have suppressed the event.
            let collected = try await eventsTask.value
            guard case let .omemoRecipientsPartial(conversation, dropped) = try #require(collected.last) else {
                Issue.record("Expected omemoRecipientsPartial event")
                return
            }
            #expect(conversation == peerJID)
            #expect(dropped.count == 2)

            await disconnectFast(client)
        }
    }

    struct CryptographicFailureTests {
        @Test func `OMEMOCryptoError becomes a cryptographic failure with its display text`() {
            let translated = OMEMOModuleError.translatingCryptoFailure(OMEMOCryptoError.hmacVerificationFailed)
            #expect(translated as? OMEMOModuleError == .cryptographicFailure("Message authentication failed"))
        }

        @Test func `CryptoKitError becomes a cryptographic failure with a fixed phrase`() {
            let translated = OMEMOModuleError.translatingCryptoFailure(CryptoKitError.incorrectKeySize)
            #expect(translated as? OMEMOModuleError == .cryptographicFailure("The encryption keys are invalid or unusable"))
        }

        @Test func `Stanza errors pass through unchanged`() {
            let translated = OMEMOModuleError.translatingCryptoFailure(
                XMPPStanzaError(errorType: .cancel, condition: .itemNotFound)
            )
            #expect((translated as? XMPPStanzaError)?.condition == .itemNotFound)
        }

        @Test func `Module errors pass through unchanged`() {
            let translated = OMEMOModuleError.translatingCryptoFailure(OMEMOModuleError.bundleNotFound)
            #expect(translated as? OMEMOModuleError == .bundleNotFound)
        }

        @Test func `Invalid stored identity key leaves the connection up without generating a device`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let valid = try makeTestOMEMOIdentity(deviceID: 4242, preKeyIDs: [1]).data
            omemoModule.configureIdentity(OMEMOModule.OMEMOIdentityData(
                deviceID: valid.deviceID,
                identityKeyRaw: Array(valid.identityKeyRaw.prefix(16)),
                signedPreKeyID: valid.signedPreKeyID,
                signedPreKeyRaw: valid.signedPreKeyRaw,
                signedPreKeySignature: valid.signedPreKeySignature,
                preKeys: valid.preKeys
            ))
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(pepModule)
            await client.register(omemoModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            #expect(omemoModule.ownIdentityData == nil)
            // Only the four handshake stanzas: no device list read, no publish.
            #expect(await mock.sentBytes.count == 4)
            await disconnectFast(client)
        }

        @Test func `Peer bundle with an invalid signature fails encrypt with a cryptographic failure`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)
            let deviceID: UInt32 = 10

            let task = Task {
                try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: [deviceID], ownDeviceIDs: []
                )
            }

            await mock.waitForSent(count: 1)
            let iqID = try await #require(extractIQID(from: mock.sentBytes[0]))
            let peer = try makeTestOMEMOIdentity(deviceID: deviceID, preKeyIDs: [1])
            let validBundle = OMEMOPreKeyManager.buildBundle(
                deviceID: OMEMODeviceID(value: deviceID),
                identityKeyPair: peer.identityKeyPair,
                signedPreKey: peer.signedPreKey,
                preKeys: peer.preKeys
            )
            var signature = validBundle.signedPreKeySignature
            signature[0] ^= 0xFF
            let corruptedBundle = OMEMOBundle(
                deviceID: validBundle.deviceID,
                identityKey: validBundle.identityKey,
                signedPreKeyID: validBundle.signedPreKeyID,
                signedPreKey: validBundle.signedPreKey,
                signedPreKeySignature: signature,
                preKeys: validBundle.preKeys
            )
            await mock.simulateReceive(bundleResultIQ(
                iqID: iqID, fromJID: peerJID, deviceID: deviceID,
                bundleEl: omemoModule.buildBundleElement(corruptedBundle)
            ))

            await #expect(throws: OMEMOModuleError.cryptographicFailure("The signed pre-key signature is invalid")) {
                _ = try await task.value
            }

            await disconnectFast(client)
        }
    }

    struct PruneStaleBundlesTests {
        /// Stub provider that seeds devices in `hasObservedHealthy: true` so
        /// prune trips the two-stale gate on the next `.stale` classification.
        /// Pass `initial: []` (or use `seed:`) for the never-healthy lineage.
        actor StubSeenDeviceClassificationProvider: SeenDeviceClassificationProviding {
            private var cache: [UInt32: SeenDeviceRecord]
            private(set) var mergeUpdates: [[UInt32: SeenDeviceRecord]] = []
            private(set) var clearAbsentCalls: [Set<UInt32>] = []
            private(set) var replaceCalls: [[UInt32: SeenDeviceRecord]] = []

            init(initial: Set<UInt32> = []) {
                var seed: [UInt32: SeenDeviceRecord] = [:]
                for id in initial {
                    seed[id] = SeenDeviceRecord(
                        deviceID: id,
                        lastClassification: .stale,
                        staleStreak: 1,
                        hasObservedHealthy: true
                    )
                }
                self.cache = seed
            }

            init(seed: [UInt32: SeenDeviceRecord]) {
                self.cache = seed
            }

            func loadSeenDevices(accountID _: String) async -> [UInt32: SeenDeviceRecord] {
                cache
            }

            func mergeSeenDevices(_ updates: [UInt32: SeenDeviceRecord], accountID _: String) async {
                mergeUpdates.append(updates)
                for (id, record) in updates {
                    cache[id] = record
                }
            }

            func clearSeenDevicesAbsent(from currentDeviceIDs: Set<UInt32>, accountID _: String) async {
                clearAbsentCalls.append(currentDeviceIDs)
                cache = cache.filter { currentDeviceIDs.contains($0.key) }
            }

            func replaceSeenDevices(_ records: [UInt32: SeenDeviceRecord], accountID _: String) async {
                replaceCalls.append(records)
                cache = records
            }

            var snapshot: [UInt32: SeenDeviceRecord] {
                cache
            }

            /// Returns the device-ID set after the most recent persistence
            /// operation, or `nil` if no operation has run yet.
            var lastUpdate: Set<UInt32>? {
                guard !mergeUpdates.isEmpty || !clearAbsentCalls.isEmpty || !replaceCalls.isEmpty else {
                    return nil
                }
                return Set(cache.keys)
            }
        }

        /// Empty seen-set on first prune: orphan devices are warn-only logged
        /// and recorded for next reconnect — no retract IQ, no re-publish.
        @Test
        func `Empty seen-set warn-only on stale device — no retract, no re-publish`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .itemNotFound]
            )

            // Seen-set should have been recorded with the full device list
            // (own + 99). No retract IQ was issued — only the bundle probe.
            let last = await stub.lastUpdate
            #expect(last?.contains(99) == true)

            let postProbeSent = await mock.sentBytes
            for bytes in postProbeSent {
                let xml = String(decoding: bytes, as: UTF8.self)
                #expect(!xml.contains("<retract"))
            }

            await disconnectFast(client)
        }

        /// Previously-seen orphan: device-list re-published trimmed first, then
        /// the bundle is retracted. This is the steady-state auto-cleanup path.
        @Test
        func `Previously-seen stale device is retracted and re-published`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [99])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .itemNotFound],
                expectedRetracts: [99]
            )

            // After retract: 99 was removed from the cache; ownDeviceID is never recorded (only probed peer IDs).
            let last = await stub.lastUpdate
            #expect(last == Set([]))

            await disconnectFast(client)
        }

        /// Previously-seen but healthy device must NOT be retracted — the
        /// `.healthy` classification path is the most common and most
        /// dangerous to break (would cause spurious retractions of live
        /// sibling bundles).
        @Test
        func `Previously-seen healthy device is not trimmed`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [99])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .healthy]
            )

            // 99 stays in the cache with the new healthy record; ownDeviceID
            // is never recorded (only probed peer IDs get records).
            let last = await stub.lastUpdate
            #expect(last == Set([99]))

            let postProbeSent = await mock.sentBytes
            for bytes in postProbeSent {
                let xml = String(decoding: bytes, as: UTF8.self)
                #expect(!xml.contains("<retract"))
            }

            await disconnectFast(client)
        }

        /// Previously-seen device returning a non-itemNotFound stanza error
        /// classifies as `.transient` — must not retract. Guards against a
        /// "drop everything that isn't a perfect success" regression.
        @Test
        func `Transient stanza error does not retract previously-seen device`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [99])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .serviceUnavailable]
            )

            let postProbeSent = await mock.sentBytes
            for bytes in postProbeSent {
                let xml = String(decoding: bytes, as: UTF8.self)
                #expect(!xml.contains("<retract"))
            }

            await disconnectFast(client)
        }

        /// Empty `<items/>` response classifies as `.transient`, NOT `.stale`
        /// — defends against a malicious own-server selectively returning
        /// empty for a sibling's live bundle.
        @Test
        func `Empty items response is transient, not stale`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [99])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .empty]
            )

            // Empty items would have triggered retract if treated as stale;
            // the new classification keeps the bundle (and the device list)
            // intact.
            let postProbeSent = await mock.sentBytes
            for bytes in postProbeSent {
                let xml = String(decoding: bytes, as: UTF8.self)
                #expect(!xml.contains("<retract"))
            }

            await disconnectFast(client)
        }

        /// Mixed seen+unseen stale IDs: when one orphan was previously seen
        /// (so it retracts) and another is brand-new-stale (warn-only), the
        /// warn-only loop must still run. The retract path trims only the
        /// previously-seen orphan; the brand-new orphan stays on the list
        /// and the seen-set anchors so the next reconnect can retract it.
        /// Locks the iter-2 reordering of the warn-only loop above the
        /// retract branch.
        @Test
        func `Mixed seen and unseen stale IDs preserves the unseen one until next reconnect`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [99])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99, 100],
                bundleProbeOutcomes: [99: .itemNotFound, 100: .itemNotFound],
                expectedRetracts: [99]
            )

            // 99 was retracted and dropped; 100 is first-stale-no-prior-healthy and stays for the next reconnect.
            let last = await stub.lastUpdate
            #expect(last == Set([100]))

            // The retract IQ went out for 99 only; 100 was warn-only logged
            // and not retracted.
            let retractIDs = await mock.sentBytes.compactMap { bytes -> UInt32? in
                let xml = String(decoding: bytes, as: UTF8.self)
                guard xml.contains("<retract") else { return nil }
                return extractBundleDeviceID(from: bytes)
            }
            #expect(retractIDs == [99])

            await disconnectFast(client)
        }

        /// Empty peer device list (single-client account): pruneStaleBundles
        /// does nothing but still anchors the seen-set to the published list,
        /// so a future shrink-then-regrow with the same orphan ID can't
        /// bypass the prior-observation gate. This is the load-bearing
        /// reason for the empty-peer-list early return.
        @Test
        func `Empty peer device list still anchors the seen-set`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: []
            )

            // Empty-peer path: cache is cleared of any sibling records that
            // remained from a prior epoch. ownDeviceID is never recorded.
            let last = await stub.lastUpdate
            #expect(last == Set([]))

            await disconnectFast(client)
        }

        /// Malformed bundle payload (well-formed PEP item containing payload
        /// that fails `parseBundleElement`) classifies as `.stale`, matching
        /// `fetchBundle`'s `bundleNotFound` semantics. Without this branch a
        /// corrupt bundle item would stay listed forever.
        @Test
        func `Malformed bundle payload classifies as stale`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [99])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .malformedPayload],
                expectedRetracts: [99]
            )

            // Malformed payload classified stale + previously seen → retract
            // path fires, trimmed list re-published.
            let postProbeSent = await mock.sentBytes
            let retractFound = postProbeSent.contains { bytes in
                let xml = String(decoding: bytes, as: UTF8.self)
                return xml.contains("<retract")
            }
            #expect(retractFound)

            await disconnectFast(client)
        }

        /// Probe cap: an attacker-shaped huge device list causes prune to
        /// skip entirely — no probe IQs, no retract, but the seen-set still
        /// anchors so the gate stays correct on the next reconnect.
        @Test
        func `Huge device list exceeds probe cap and prune skips`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            // Build a list larger than `pruneProbeCap` (64). Use 100.
            // Drive connect manually instead of via the standard helper,
            // because the helper assumes one probe IQ per listed device,
            // and the cap path issues zero probes.
            let attackerList: [UInt32] = (1 ... 100).map(UInt32.init)
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(pepModule)
            await client.register(omemoModule)
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)

            await mock.waitForSent(count: 5)
            let id5 = try await #require(extractIQID(from: mock.sentBytes[4]))
            await mock.simulateReceive(makeOwnDeviceListResultIQ(iqID: id5, devices: attackerList))
            await mock.waitForSent(count: 6)
            let id6 = try await #require(extractIQID(from: mock.sentBytes[5]))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(id6)\"/>")
            await mock.waitForSent(count: 7)
            let id7 = try await #require(extractIQID(from: mock.sentBytes[6]))
            let ownDeviceID = try await #require(extractBundleDeviceID(from: mock.sentBytes[6]))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(id7)\"/>")
            try await connectTask.value

            // Probe cap fires: zero probe IQs sent. Total stanzas == 7.
            let total = await mock.sentBytes.count
            #expect(total == 7)

            // Over-cap path does NOT touch the cache (attacker-provided list is untrustworthy; preserving prior
            // cache is the safer default). Without a wired emergency-retract closure the prune bails — recovery is
            // covered by the closure-path test.
            _ = ownDeviceID // unused after cap-path bails
            let last = await stub.lastUpdate
            #expect(last == nil)

            await disconnectFast(client)
        }

        /// A retract names the device's item on the shared bundles node, the item its publish wrote. A wrong
        /// item id would be a silent no-op on most PEP servers.
        @Test
        func `Retract IQ names the device's item on the bundles node`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [99])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .itemNotFound],
                expectedRetracts: [99]
            )

            let allBytes = await mock.sentBytes
            let retractIQ = allBytes.first { bytes in
                let xml = String(decoding: bytes, as: UTF8.self)
                return xml.contains("<retract")
            }
            let xml = try #require(retractIQ.map { String(decoding: $0, as: UTF8.self) })
            #expect(xml.contains("<retract node=\"\(XMPPNamespaces.omemoBundles)\"><item id=\"99\"/>"))

            await disconnectFast(client)
        }

        /// Re-publish failure: when `publishDeviceList` throws during the
        /// retract path, `pruneStaleBundles` rethrows. The connect chain
        /// catches and warn-only logs — but no retract is issued (because
        /// the trim was never published) and the seen-set is NOT updated to
        /// the trimmed list. Locks the rollback semantics documented in
        /// `retractAndRePublish`'s docstring ("publish FIRST so a subsequent
        /// retract failure leaves PEP no worse off").
        @Test
        func `Republish failure rethrows and skips retract`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let stub = StubSeenDeviceClassificationProvider(initial: [99])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(pepModule)
            await client.register(omemoModule)
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)

            // Standard OMEMO connect: device-list retrieve, publish, bundle publish.
            await mock.waitForSent(count: 5)
            let id5 = try await #require(extractIQID(from: mock.sentBytes[4]))
            await mock.simulateReceive(makeOwnDeviceListResultIQ(iqID: id5, devices: [99]))
            await mock.waitForSent(count: 6)
            let id6 = try await #require(extractIQID(from: mock.sentBytes[5]))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(id6)\"/>")
            await mock.waitForSent(count: 7)
            let id7 = try await #require(extractIQID(from: mock.sentBytes[6]))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(id7)\"/>")

            // Bundle probe: classify deviceID 99 as stale.
            await mock.waitForSent(count: 8)
            let probeID = try await #require(extractIQID(from: mock.sentBytes[7]))
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: probeID, fromJID: pruneTestUserJID))

            // Re-publish trimmed device list FAILS with service-unavailable.
            await mock.waitForSent(count: 9)
            let republishID = try await #require(extractIQID(from: mock.sentBytes[8]))
            await mock.simulateReceive(makeServiceUnavailableIQ(iqID: republishID, fromJID: pruneTestUserJID))

            // Connect must still complete — the rethrow is caught by handleConnect.
            try await connectTask.value

            // Critically, no retract IQ must have been sent — the trim was
            // never confirmed at PEP, so retracting orphan bundles would
            // leave the device list and bundles inconsistent.
            let total = await mock.sentBytes.count
            #expect(total == 9)
            let allBytes = await mock.sentBytes
            for bytes in allBytes {
                let xml = String(decoding: bytes, as: UTF8.self)
                #expect(!xml.contains("<retract"))
            }
            // Seen-set must NOT be updated to the trimmed list — the retract
            // path bailed before that write, so no update was ever issued.
            let last = await stub.lastUpdate
            #expect(last == nil)

            await disconnectFast(client)
        }

        // MARK: - Two-Stale Healthy-Observation Gate

        /// `healthy → stale` (streak: 0 → 1) records the mid-streak state
        /// but does NOT retract. The gate fires only on the second stale.
        @Test
        func `Single stale after healthy does not retract`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            // Seed with a confirmed-healthy record (staleStreak: 0). Under
            // the new gate, one `.stale` observation pushes the streak to 1
            // — still below the threshold of 2.
            let healthySeed = SeenDeviceRecord(
                deviceID: 99, lastClassification: .healthy,
                staleStreak: 0, hasObservedHealthy: true
            )
            let stub = StubSeenDeviceClassificationProvider(seed: [99: healthySeed])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .itemNotFound]
            )

            // No retract IQ should have been sent — only one stale strike.
            let allBytes = await mock.sentBytes
            for bytes in allBytes {
                let xml = String(decoding: bytes, as: UTF8.self)
                #expect(!xml.contains("<retract"))
            }
            // The record was updated to (.stale, staleStreak: 1, observed: true).
            let snapshot = await stub.snapshot
            let record = try #require(snapshot[99])
            #expect(record.lastClassification == .stale)
            #expect(record.staleStreak == 1)
            #expect(record.hasObservedHealthy == true)

            await disconnectFast(client)
        }

        /// `healthy → stale → healthy` resets the streak to 0 and does not
        /// retract. `hasObservedHealthy` stays `true` for the lineage.
        @Test
        func `Healthy classification resets stale streak`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            // Seed mid-streak: hasObservedHealthy: true, staleStreak: 1.
            let midStreakSeed = SeenDeviceRecord(
                deviceID: 99, lastClassification: .stale,
                staleStreak: 1, hasObservedHealthy: true
            )
            let stub = StubSeenDeviceClassificationProvider(seed: [99: midStreakSeed])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .healthy]
            )

            // No retract IQ — healthy classification reset the streak.
            let allBytes = await mock.sentBytes
            for bytes in allBytes {
                let xml = String(decoding: bytes, as: UTF8.self)
                #expect(!xml.contains("<retract"))
            }
            // Record reset: (.healthy, 0, true).
            let snapshot = await stub.snapshot
            let record = try #require(snapshot[99])
            #expect(record.lastClassification == .healthy)
            #expect(record.staleStreak == 0)
            #expect(record.hasObservedHealthy == true)

            await disconnectFast(client)
        }

        /// `unseen → stale → stale` reaches staleStreak: 2 but
        /// `hasObservedHealthy` stays `false`, so the gate does NOT fire.
        /// Defends against a never-confirmed-healthy device being retracted
        /// after two reconnects.
        @Test
        func `Unseen-stale-stale lineage does not retract`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            // Seed: previously observed as stale once, never healthy.
            let neverHealthySeed = SeenDeviceRecord(
                deviceID: 99, lastClassification: .stale,
                staleStreak: 1, hasObservedHealthy: false
            )
            let stub = StubSeenDeviceClassificationProvider(seed: [99: neverHealthySeed])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .itemNotFound]
            )

            // No retract IQ — without a prior healthy observation the gate
            // refuses to act.
            let allBytes = await mock.sentBytes
            for bytes in allBytes {
                let xml = String(decoding: bytes, as: UTF8.self)
                #expect(!xml.contains("<retract"))
            }
            // Streak advanced to 2 but hasObservedHealthy is still false.
            let snapshot = await stub.snapshot
            let record = try #require(snapshot[99])
            #expect(record.staleStreak == 2)
            #expect(record.hasObservedHealthy == false)

            await disconnectFast(client)
        }

        /// `.transient` mid-streak preserves the previous record verbatim.
        /// A network blip must not penalize an established healthy lineage.
        @Test
        func `Transient classification preserves previous record verbatim`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let priorRecord = SeenDeviceRecord(
                deviceID: 99, lastClassification: .stale,
                staleStreak: 1, hasObservedHealthy: true
            )
            let stub = StubSeenDeviceClassificationProvider(seed: [99: priorRecord])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .empty] // classifies as transient
            )

            // The record must remain exactly what it was — no streak bump,
            // no classification change. A future stale would still fire the
            // gate, but a transient does not advance toward retract.
            let snapshot = await stub.snapshot
            let record = try #require(snapshot[99])
            #expect(record.lastClassification == .stale)
            #expect(record.staleStreak == 1)
            #expect(record.hasObservedHealthy == true)

            await disconnectFast(client)
        }

        /// Bypass-defense: a previously-healthy device that disappears from
        /// PEP entirely must be cleared from the cache. Without this, a
        /// peer could later regrow the same deviceID and inherit
        /// `hasObservedHealthy: true` to bypass the gate.
        @Test
        func `Device removed from PEP list is cleared from cache`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            // Seed device X as healthy; the upcoming list contains only Y.
            let healthySeed = SeenDeviceRecord(
                deviceID: 88, lastClassification: .healthy,
                staleStreak: 0, hasObservedHealthy: true
            )
            let stub = StubSeenDeviceClassificationProvider(seed: [88: healthySeed])
            omemoModule.configureSeenDeviceClassificationProvider(stub, accountID: "acct-1")

            let (client, _) = try await makeConnectedClientWithDeviceList(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule,
                otherDeviceIDsOnList: [99],
                bundleProbeOutcomes: [99: .healthy]
            )

            // After prune: device 88 is gone (no longer in ownDeviceList),
            // 99 was probed and recorded as healthy.
            let snapshot = await stub.snapshot
            #expect(snapshot[88] == nil)
            #expect(snapshot[99]?.lastClassification == .healthy)

            await disconnectFast(client)
        }

        /// Encrypt-path concurrency cap: chunked iteration completes every
        /// recipient device but never spawns more than `encryptConcurrencyCap`
        /// (64) concurrent bundle-fetch IQs. The cap chunks recipients into
        /// windows that complete before the next starts, so the test drains
        /// the mock's outbox one stanza at a time rather than waiting for
        /// all IQs up front — that wait would deadlock against the chunk
        /// boundary (the second chunk doesn't send until the first chunk's
        /// responses arrive).
        @Test
        func `Encrypt fan-out across many devices completes every recipient`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            // 100 recipients > the 64-cap → at least one chunk boundary
            // the test has to cross.
            let recipientIDs: [UInt32] = (1 ... 100).map(UInt32.init)
            let task = Task {
                try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: recipientIDs, ownDeviceIDs: []
                )
            }

            // Drain one stanza at a time. Asserting strict in-flight depth
            // would race the scheduler; asserting that every device gets
            // exactly one bundle fetch and the encrypt completes is
            // sufficient to confirm chunked iteration covers all recipients.
            var seenDevices: Set<UInt32> = []
            var drained = 0
            while drained < recipientIDs.count {
                await mock.waitForSent(count: drained + 1)
                let bytes = await mock.sentBytes[drained]
                let iqID = try #require(extractIQID(from: bytes))
                let deviceID = try #require(extractBundleDeviceID(from: bytes))
                seenDevices.insert(deviceID)
                await mock.simulateReceive(makeItemNotFoundIQ(iqID: iqID, fromJID: peerJID))
                drained += 1
            }
            #expect(seenDevices == Set(recipientIDs))

            // All recipients were dropped (item-not-found) so the encrypt
            // throws noUsableRecipientDevices — confirms the cap path
            // completes every device rather than stopping at the cap.
            await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) {
                _ = try await task.value
            }

            await disconnectFast(client)
        }
    }

    struct OMEMORecipientsPartialEventTests {
        @Test
        func `Event fires when peer device's bundle is missing during encrypt`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .omemoRecipientsPartial = event { return true }
                    return false
                }
            }

            let task = Task {
                try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: [10, 11], ownDeviceIDs: []
                )
            }

            await mock.waitForSent(count: 2)
            let sent = await mock.sentBytes
            let id1 = try #require(extractIQID(from: sent[0]))
            let id2 = try #require(extractIQID(from: sent[1]))
            let dev2 = try #require(extractBundleDeviceID(from: sent[1]))
            // First fetch fails with item-not-found; second returns a valid bundle.
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: id1, fromJID: peerJID))
            let validBundleIQ = try makeValidBundleResultIQ(
                iqID: id2, deviceID: dev2, fromJID: peerJID, module: omemoModule
            )
            await mock.simulateReceive(validBundleIQ)

            let elements = try await task.value
            #expect(elements.droppedRecipients.count == 1)
            let collected = try await eventsTask.value
            guard case let .omemoRecipientsPartial(conversation, dropped) = try #require(collected.last) else {
                Issue.record("Expected omemoRecipientsPartial event")
                return
            }
            #expect(conversation == peerJID)
            #expect(dropped.count == 1)
            // The dropped device is whichever the loop classified — not dev2 (which succeeded).
            #expect(dropped[0].jid == peerJID)
            #expect(dropped[0].deviceID != dev2)

            await disconnectFast(client)
        }

        @Test
        func `Event fires for encryptGroupMessage with conversation == roomJID`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)
            let roomJID = try #require(BareJID(localPart: "room", domainPart: "muc.example.com"))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .omemoRecipientsPartial = event { return true }
                    return false
                }
            }

            let task = Task {
                try await omemoModule.encryptGroupMessage(
                    plaintext: "hi room", roomJID: roomJID,
                    recipients: [(jid: peerJID, deviceIDs: [10, 11])], ownDeviceIDs: []
                )
            }

            await mock.waitForSent(count: 2)
            let sent = await mock.sentBytes
            let id1 = try #require(extractIQID(from: sent[0]))
            let id2 = try #require(extractIQID(from: sent[1]))
            let dev2 = try #require(extractBundleDeviceID(from: sent[1]))
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: id1, fromJID: peerJID))
            let validBundleIQ = try makeValidBundleResultIQ(
                iqID: id2, deviceID: dev2, fromJID: peerJID, module: omemoModule
            )
            await mock.simulateReceive(validBundleIQ)

            let elements = try await task.value
            #expect(elements.droppedRecipients.count == 1)
            let collected = try await eventsTask.value
            guard case let .omemoRecipientsPartial(conversation, dropped) = try #require(collected.last) else {
                Issue.record("Expected omemoRecipientsPartial event")
                return
            }
            // The conversation field labels the MUC room, not the peer JID
            // — that's the diagnostic point of the new roomJID parameter.
            #expect(conversation == roomJID)
            #expect(dropped.count == 1)
            #expect(dropped[0].jid == peerJID)

            await disconnectFast(client)
        }

        @Test
        func `Event fires when an own-device's bundle is missing during encrypt`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .omemoRecipientsPartial = event { return true }
                    return false
                }
            }

            // Recipient peer succeeds; the own-device side gets one explicit
            // own-device ID with no bundle. The dropped union must include
            // that own-device drop and the event must fire for it. Peer
            // encryption awaits its response before own encryption starts,
            // so the IQs are sequential: first peer (42), then own (777).
            let task = Task {
                try await omemoModule.encryptMessage(
                    plaintext: "hello", to: peerJID,
                    recipientDeviceIDs: [42], ownDeviceIDs: [777]
                )
            }

            await mock.waitForSent(count: 1)
            let peerBytes = await mock.sentBytes[0]
            let peerID = try #require(extractIQID(from: peerBytes))
            let peerDeviceID = try #require(extractBundleDeviceID(from: peerBytes))
            let validBundleIQ = try makeValidBundleResultIQ(
                iqID: peerID, deviceID: peerDeviceID, fromJID: peerJID, module: omemoModule
            )
            await mock.simulateReceive(validBundleIQ)

            await mock.waitForSent(count: 2)
            let ownBytes = await mock.sentBytes[1]
            let ownID = try #require(extractIQID(from: ownBytes))
            // The request addressed the own bare JID ("user@example.com"), so the
            // reply needs a `from` that `IQReplyPolicy` accepts for it. Any other
            // `from` leaves sendIQ waiting out its 30-second timeout.
            let ownJID = try #require(BareJID(localPart: "user", domainPart: "example.com"))
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: ownID, fromJID: ownJID))

            let elements = try await task.value
            // Exactly one own-device drop in the union.
            #expect(elements.droppedRecipients.count == 1)
            #expect(elements.droppedRecipients[0].deviceID == 777)

            let collected = try await eventsTask.value
            guard case let .omemoRecipientsPartial(_, dropped) = try #require(collected.last) else {
                Issue.record("Expected omemoRecipientsPartial event")
                return
            }
            #expect(dropped.contains { $0.deviceID == 777 })

            await disconnectFast(client)
        }
    }

    struct PublishOptionsTests {
        @Test func `Bundle publish IQ contains XEP-0223 publish-options form`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, artifacts) = try await makeConnectedClient(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule
            )

            let bundleIQ = String(decoding: artifacts.bundlePublishIQ, as: UTF8.self)

            #expect(bundleIQ.contains("publish-options"))
            #expect(bundleIQ.contains("var=\"FORM_TYPE\""))
            #expect(bundleIQ.contains("<value>http://jabber.org/protocol/pubsub#publish-options</value>"))
            #expect(bundleIQ.contains("var=\"pubsub#persist_items\""))
            // The persist_items value follows its field — assert presence of "true" within the form.
            #expect(bundleIQ.contains("<value>true</value>"))
            #expect(bundleIQ.contains("var=\"pubsub#access_model\""))
            #expect(bundleIQ.contains("<value>open</value>"))
            // Every device's bundle is an item of one node, which keeps them all.
            #expect(bundleIQ.contains("var=\"pubsub#max_items\"") && bundleIQ.contains("<value>max</value>"))

            // The device-list publish caps max_items at 1.
            let deviceListIQ = String(decoding: artifacts.deviceListPublishIQ, as: UTF8.self)
            #expect(deviceListIQ.contains("var=\"pubsub#max_items\""))
            #expect(deviceListIQ.contains("<value>1</value>"))

            await disconnectFast(client)
        }
    }

    struct EnsureOwnDeviceInListTests {
        /// When the server's own device-list already contains this device, `ensureOwnDeviceInList` takes
        /// the no-publish early return (`if !devices.contains(deviceID.value)` is false): the stanza after
        /// the device-list retrieve is the bundle publish, NOT a device-list publish. Contrast the empty-list
        /// path (`makeConnectedClient`), which appends the device and publishes the list at the same offset.
        @Test func `No device-list publish when own device already listed`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let deviceID: UInt32 = 4242
            try omemoModule.configureIdentity(makeTestOMEMOIdentity(deviceID: deviceID, preKeyIDs: [1]).data)

            let client = try await makeConnectedClientWithOwnDeviceListed(
                mock: mock, omemoModule: omemoModule, pepModule: pepModule, deviceID: deviceID
            )

            let sent = await mock.sentBytes
            // Handshake (0–3), own device-list retrieve (4), then the bundle publish (5) — no list publish.
            let retrieve = String(decoding: sent[4], as: UTF8.self)
            #expect(retrieve.contains("<items") && retrieve.contains(XMPPNamespaces.omemoDevices))
            let afterRetrieve = String(decoding: sent[5], as: UTF8.self)
            #expect(afterRetrieve.contains("<publish") && afterRetrieve.contains(XMPPNamespaces.omemoBundles))
            // No device-list publish IQ was issued anywhere during connect.
            for bytes in sent {
                let xml = String(decoding: bytes, as: UTF8.self)
                #expect(!(xml.contains("<publish") && xml.contains("node=\"\(XMPPNamespaces.omemoDevices)\"")))
            }

            await disconnectFast(client)
        }
    }

    struct ModuleKexRoundTripTests {
        /// Drives a real `OMEMOModule.decryptKexKey` end-to-end so the consumed-pre-key recording branch
        /// runs: an initiator module encrypts a KEX targeting the recipient's *real* published bundle (built
        /// from the recipient's own keys — `makeValidBundleResultIQ`'s throwaway keys would fail decrypt
        /// before the `usedPreKeyIDs.insert`), then the recipient handles the message through its public
        /// `handleMessage` path and reports the pre-key as consumed.
        @Test func `KEX round-trip records the consumed pre-key`() async throws {
            let recipientDeviceID: UInt32 = 200
            let targetedPreKeyID: UInt32 = 7
            let recipient = try makeTestOMEMOIdentity(deviceID: recipientDeviceID, preKeyIDs: [targetedPreKeyID])

            // Connect the recipient so its identity is restored and its pre-key is in scope.
            let recipientMock = MockTransport()
            let recipientPep = PEPModule()
            let recipientOmemo = OMEMOModule(pepModule: recipientPep)
            recipientOmemo.configureIdentity(recipient.data)
            let recipientClient = try await makeConnectedClientWithOwnDeviceListed(
                mock: recipientMock, omemoModule: recipientOmemo,
                pepModule: recipientPep, deviceID: recipientDeviceID
            )

            let message = try await makeKEXMessage(to: recipient, plaintext: "secret")

            // Feed the initiator's KEX-bearing message into the recipient's public message-handling path.
            let recipientEvents = Task { try await collectEvents(from: recipientClient, until: isEncryptedMessage) }
            try recipientOmemo.handleMessage(XMPPMessage(element: message))

            #expect(try await decryptedBody(in: recipientEvents.value) == "secret")
            // The targeted pre-key was consumed during the responder key agreement.
            #expect(recipientOmemo.consumedPreKeyIDs() == [targetedPreKeyID])

            await disconnectFast(recipientClient)
        }
    }
}

// MARK: - Helpers

private func makeModule() -> OMEMOModule {
    OMEMOModule(pepModule: PEPModule())
}

/// The two connect-time PEP publish IQ stanzas captured by
/// `makeConnectedClient` before it clears the mock's sent buffer. Tests inspect
/// these directly instead of indexing into post-handshake `mock.sentBytes`
/// offsets. The own device-list retrieve IQ is consumed during connect and not
/// surfaced — add it here if a future test needs to inspect it.
struct OMEMOConnectArtifacts {
    let deviceListPublishIQ: [UInt8]
    let bundlePublishIQ: [UInt8]
}

/// Drives the standard handshake (4 stanzas) followed by OMEMO's connect-time
/// PEP IQ flow: own device-list retrieve, device-list publish, bundle publish.
/// After this returns, `omemoModule.ownIdentityData` is populated. The mock's
/// `sentBytes` is cleared so post-handshake tests can index from 0; the two
/// publish IQ byte buffers (device-list publish, bundle publish) are returned
/// via `OMEMOConnectArtifacts`. The own-device-list retrieve IQ is consumed
/// in-place and not surfaced.
func makeConnectedClient(
    mock: MockTransport,
    omemoModule: OMEMOModule,
    pepModule: PEPModule
) async throws -> (XMPPClient, OMEMOConnectArtifacts) {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(pepModule)
    await client.register(omemoModule)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)

    // PEP retrieve own device list. Empty result → module appends its
    // freshly generated device ID and publishes.
    await mock.waitForSent(count: 5)
    let id5 = try await #require(extractIQID(from: mock.sentBytes[4]))
    await mock.simulateReceive("<iq type=\"result\" id=\"\(id5)\"/>")

    // Device list publish.
    await mock.waitForSent(count: 6)
    let deviceListPublishIQ = await mock.sentBytes[5]
    let id6 = try #require(extractIQID(from: deviceListPublishIQ))
    await mock.simulateReceive("<iq type=\"result\" id=\"\(id6)\"/>")

    // Own bundle publish.
    await mock.waitForSent(count: 7)
    let bundlePublishIQ = await mock.sentBytes[6]
    let id7 = try #require(extractIQID(from: bundlePublishIQ))
    await mock.simulateReceive("<iq type=\"result\" id=\"\(id7)\"/>")

    try await connectTask.value
    await mock.clearSentBytes()

    return (client, OMEMOConnectArtifacts(
        deviceListPublishIQ: deviceListPublishIQ,
        bundlePublishIQ: bundlePublishIQ
    ))
}

private let peerJID = BareJID(localPart: "peer", domainPart: "example.com")!
private let ownJID = BareJID(localPart: "user", domainPart: "example.com")!

/// Builds a `<iq type='result'>` carrying a device-list payload for the given
/// device IDs.
private func makeDeviceListResultIQ(iqID: String, fromJID: BareJID, devices: [UInt32]) -> String {
    var deviceXML = ""
    for id in devices {
        deviceXML += "<device id=\"\(id)\"/>"
    }
    return """
    <iq type="result" id="\(iqID)" from="\(fromJID.description)">\
    <pubsub xmlns="http://jabber.org/protocol/pubsub">\
    <items node="urn:xmpp:omemo:2:devices">\
    <item id="current"><devices xmlns="urn:xmpp:omemo:2">\(deviceXML)</devices></item>\
    </items></pubsub></iq>
    """
}

/// Builds a `<iq type='error'>` with `<item-not-found/>` for the given id.
private func makeItemNotFoundIQ(iqID: String, fromJID: BareJID) -> String {
    """
    <iq type="error" id="\(iqID)" from="\(fromJID.description)">\
    <error type="cancel">\
    <item-not-found xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>\
    </error></iq>
    """
}

/// Wraps a published bundle element in the PEP `<iq type='result'>` items envelope, as item `deviceID` of the shared
/// bundles node.
private func bundleResultIQ(iqID: String, fromJID: BareJID, deviceID: UInt32, bundleEl: XMLElement) -> String {
    """
    <iq type="result" id="\(iqID)" from="\(fromJID.description)">\
    <pubsub xmlns="http://jabber.org/protocol/pubsub">\
    <items node="\(XMPPNamespaces.omemoBundles)">\
    <item id="\(deviceID)">\(bundleEl.xmlString)</item>\
    </items></pubsub></iq>
    """
}

/// Builds a `<iq type='result'>` carrying a freshly-generated valid OMEMO
/// bundle for the given peer device, suitable for X3DH initiator agreement.
private func makeValidBundleResultIQ(
    iqID: String, deviceID: UInt32, fromJID: BareJID, module: OMEMOModule
) throws -> String {
    let identityKeyPair = OMEMOIdentityKeyPair()
    let signedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(
        keyID: 1, identityKey: identityKeyPair
    )
    let preKey = OMEMOPreKey(keyID: 1)
    let bundle = OMEMOPreKeyManager.buildBundle(
        deviceID: OMEMODeviceID(value: deviceID),
        identityKeyPair: identityKeyPair,
        signedPreKey: signedPreKey,
        preKeys: [preKey]
    )
    return bundleResultIQ(iqID: iqID, fromJID: fromJID, deviceID: deviceID, bundleEl: module.buildBundleElement(bundle))
}

/// Builds a `<iq type='result'>` carrying the bundle for `identity`'s real keys, so a KEX encrypted to it
/// is decryptable by a module configured with the same identity — unlike `makeValidBundleResultIQ`, whose
/// throwaway keys discard the private halves the responder needs.
func makeBundleResultIQ(
    iqID: String, fromJID: BareJID, identity: TestOMEMOIdentity, module: OMEMOModule
) -> String {
    let bundle = OMEMOPreKeyManager.buildBundle(
        deviceID: OMEMODeviceID(value: identity.data.deviceID),
        identityKeyPair: identity.identityKeyPair,
        signedPreKey: identity.signedPreKey,
        preKeys: identity.preKeys
    )
    return bundleResultIQ(
        iqID: iqID, fromJID: fromJID, deviceID: identity.data.deviceID, bundleEl: module.buildBundleElement(bundle)
    )
}

/// A KEX `<message>` to `recipient`'s device from a separately connected initiator with a generated identity. The
/// initiator fetches the recipient's real bundle, so a module configured with `recipient` can decrypt it.
func makeKEXMessage(to recipient: TestOMEMOIdentity, plaintext: String) async throws -> XMLElement {
    let mock = MockTransport()
    let pepModule = PEPModule()
    let omemoModule = OMEMOModule(pepModule: pepModule)
    let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: omemoModule, pepModule: pepModule)

    // The recipient's own JID on the wire is `user@example.com` (the connect helpers' credentials).
    let recipientJID = try #require(BareJID(localPart: "user", domainPart: "example.com"))
    let encryptTask = Task {
        try await omemoModule.encryptMessage(
            plaintext: plaintext, to: recipientJID,
            recipientDeviceIDs: [recipient.data.deviceID], ownDeviceIDs: []
        )
    }
    await mock.waitForSent(count: 1)
    let fetchID = try await #require(extractIQID(from: mock.sentBytes[0]))
    await mock.simulateReceive(makeBundleResultIQ(
        iqID: fetchID, fromJID: recipientJID, identity: recipient, module: omemoModule
    ))
    let elements = try await encryptTask.value
    await disconnectFast(client)

    // The initiator signs in with the recipient's credentials, so its envelope names that account as the sender.
    var message = XMLElement(name: "message", attributes: [
        "from": "\(recipientJID)/i", "to": recipientJID.description
    ])
    message.addChild(elements.encrypted)
    return message
}

func isEncryptedMessage(_ event: XMPPEvent) -> Bool {
    if case .omemoEncryptedMessageReceived = event { return true }
    return false
}

/// The decrypted body of the last event, which `isEncryptedMessage` ends the collection on.
func decryptedBody(in events: [XMPPEvent]) -> String? {
    events.last.flatMap(decryptedMessage(of:))?.body
}

/// Extracts the bundle device ID, the item id, from a captured `<iq>` that fetches or publishes a bundle.
private func extractBundleDeviceID(from bytes: [UInt8]) -> UInt32? {
    let xml = String(decoding: bytes, as: UTF8.self)
    guard xml.contains("node=\"\(XMPPNamespaces.omemoBundles)\""), let itemRange = xml.range(of: "<item id=\"") else { return nil }
    let after = xml[itemRange.upperBound...]
    guard let endQuote = after.firstIndex(of: "\"") else { return nil }
    return UInt32(after[after.startIndex ..< endQuote])
}

/// Possible mock responses to a `pruneStaleBundles` per-device probe.
private enum BundleProbeOutcome {
    case itemNotFound
    case healthy
    case empty
    /// A stanza error other than `item-not-found`. Drives the `.transient`
    /// classification path.
    case serviceUnavailable
    /// A successful PEP item whose payload fails `parseBundleElement`.
    /// Drives the `.stale` classification path through the parse-check.
    case malformedPayload
}

/// Drives the standard handshake plus OMEMO connect with a non-empty
/// device-list response, then drives the pruneStaleBundles probe flow.
/// Returns the connected client and the module's own device ID.
///
/// `otherDeviceIDsOnList` are the deviceIDs the server returns from the
/// device-list retrieve IQ (the module appends its own afterwards).
/// `bundleProbeOutcomes` maps each non-own deviceID to the response the test
/// wants to inject; missing entries default to `.empty` (which classifies as
/// transient — no retract regardless of seen-set).
/// `expectedRetracts` lists deviceIDs the test expects to be retracted —
/// when non-empty, the helper waits for the trimmed device-list re-publish
/// IQ followed by each retract IQ and acks them all.
private func makeConnectedClientWithDeviceList(
    mock: MockTransport,
    omemoModule: OMEMOModule,
    pepModule: PEPModule,
    otherDeviceIDsOnList: [UInt32],
    bundleProbeOutcomes: [UInt32: BundleProbeOutcome] = [:],
    expectedRetracts: [UInt32] = []
) async throws -> (XMPPClient, UInt32) {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(pepModule)
    await client.register(omemoModule)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)

    // Own device-list retrieve — return list with `otherDeviceIDsOnList`.
    await mock.waitForSent(count: 5)
    let id5 = try await #require(extractIQID(from: mock.sentBytes[4]))
    await mock.simulateReceive(makeOwnDeviceListResultIQ(iqID: id5, devices: otherDeviceIDsOnList))

    // Device-list publish (module appended its own ID).
    await mock.waitForSent(count: 6)
    let id6 = try await #require(extractIQID(from: mock.sentBytes[5]))
    await mock.simulateReceive("<iq type=\"result\" id=\"\(id6)\"/>")

    // Bundle publish.
    await mock.waitForSent(count: 7)
    let bundlePublishBytes = await mock.sentBytes[6]
    let id7 = try #require(extractIQID(from: bundlePublishBytes))
    let ownDeviceID = try #require(extractBundleDeviceID(from: bundlePublishBytes))
    await mock.simulateReceive("<iq type=\"result\" id=\"\(id7)\"/>")

    // pruneStaleBundles fires per-device probes (parallel within chunks of 4).
    let probeCount = otherDeviceIDsOnList.count
    try await respondToBundleProbes(
        mock: mock, omemoModule: omemoModule,
        probeCount: probeCount, outcomes: bundleProbeOutcomes
    )

    // Retract path: re-publish trimmed device list, then retract each orphan.
    try await respondToRetractFlow(
        mock: mock, startingSentCount: 7 + probeCount,
        expectedRetracts: expectedRetracts
    )

    try await connectTask.value
    return (client, ownDeviceID)
}

private let pruneTestUserJID = BareJID(localPart: "user", domainPart: "example.com")!

/// Acks the per-device bundle-probe IQs that `pruneStaleBundles` issues with
/// the response specified by `outcomes` (defaults to `.empty`).
private func respondToBundleProbes(
    mock: MockTransport, omemoModule: OMEMOModule,
    probeCount: Int, outcomes: [UInt32: BundleProbeOutcome]
) async throws {
    guard probeCount > 0 else { return }
    await mock.waitForSent(count: 7 + probeCount)
    let probeBytes = await mock.sentBytes
    for offset in 0 ..< probeCount {
        let probeIQ = probeBytes[7 + offset]
        let probeID = try #require(extractIQID(from: probeIQ))
        let probedDeviceID = try #require(extractBundleDeviceID(from: probeIQ))
        let outcome = outcomes[probedDeviceID] ?? .empty
        switch outcome {
        case .itemNotFound:
            await mock.simulateReceive(makeItemNotFoundIQ(iqID: probeID, fromJID: pruneTestUserJID))
        case .empty:
            await mock.simulateReceive(makeEmptyBundleResultIQ(iqID: probeID))
        case .healthy:
            let bundleIQ = try makeValidBundleResultIQ(
                iqID: probeID, deviceID: probedDeviceID,
                fromJID: pruneTestUserJID, module: omemoModule
            )
            await mock.simulateReceive(bundleIQ)
        case .serviceUnavailable:
            await mock.simulateReceive(makeServiceUnavailableIQ(iqID: probeID, fromJID: pruneTestUserJID))
        case .malformedPayload:
            await mock.simulateReceive(makeMalformedBundleResultIQ(iqID: probeID, deviceID: probedDeviceID))
        }
    }
}

/// `<iq type='result'>` carrying a non-empty `<items/>` whose item payload
/// is missing every required bundle field. `parseBundleElement` returns nil,
/// so `probeBundle` classifies as `.stale`.
private func makeMalformedBundleResultIQ(iqID: String, deviceID: UInt32) -> String {
    """
    <iq type="result" id="\(iqID)">\
    <pubsub xmlns="http://jabber.org/protocol/pubsub">\
    <items node="urn:xmpp:omemo:2:bundles">\
    <item id="\(deviceID)"><bundle xmlns="urn:xmpp:omemo:2"/></item>\
    </items></pubsub></iq>
    """
}

/// Builds a `<iq type='error'>` with `<service-unavailable/>` for the given id.
private func makeServiceUnavailableIQ(iqID: String, fromJID: BareJID) -> String {
    """
    <iq type="error" id="\(iqID)" from="\(fromJID.description)">\
    <error type="cancel">\
    <service-unavailable xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>\
    </error></iq>
    """
}

/// Acks the post-probe device-list re-publish IQ followed by per-orphan
/// retract IQs that `pruneStaleBundles` issues when the seen-set says retract.
private func respondToRetractFlow(
    mock: MockTransport, startingSentCount: Int, expectedRetracts: [UInt32]
) async throws {
    guard !expectedRetracts.isEmpty else { return }
    var nextSent = startingSentCount
    await mock.waitForSent(count: nextSent + 1)
    let republishID = try await #require(extractIQID(from: mock.sentBytes[nextSent]))
    await mock.simulateReceive("<iq type=\"result\" id=\"\(republishID)\"/>")
    nextSent += 1

    for _ in expectedRetracts {
        await mock.waitForSent(count: nextSent + 1)
        let retractID = try await #require(extractIQID(from: mock.sentBytes[nextSent]))
        await mock.simulateReceive("<iq type=\"result\" id=\"\(retractID)\"/>")
        nextSent += 1
    }
}

/// `<iq type='result'>` carrying a device-list payload with no `from`
/// attribute — the module's own device-list retrieve uses the user's own
/// server, which doesn't typically echo `from`.
private func makeOwnDeviceListResultIQ(iqID: String, devices: [UInt32]) -> String {
    var deviceXML = ""
    for id in devices {
        deviceXML += "<device id=\"\(id)\"/>"
    }
    return """
    <iq type="result" id="\(iqID)">\
    <pubsub xmlns="http://jabber.org/protocol/pubsub">\
    <items node="urn:xmpp:omemo:2:devices">\
    <item id="current"><devices xmlns="urn:xmpp:omemo:2">\(deviceXML)</devices></item>\
    </items></pubsub></iq>
    """
}

/// `<iq type='result'>` carrying an empty `<items/>` payload — classified as
/// `.transient` by `probeBundle` (a hostile or replicating server might
/// answer empty for a sibling's live bundle, so empty-items is ambiguous and
/// must not trigger retract).
private func makeEmptyBundleResultIQ(iqID: String) -> String {
    """
    <iq type="result" id="\(iqID)">\
    <pubsub xmlns="http://jabber.org/protocol/pubsub">\
    <items node="urn:xmpp:omemo:2:bundles"/>\
    </pubsub></iq>
    """
}

private func makeTestBundle() -> OMEMOBundle {
    OMEMOBundle(
        deviceID: OMEMODeviceID(value: 42),
        identityKey: Array(repeating: 0x01, count: 32),
        signedPreKeyID: 1,
        signedPreKey: Array(repeating: 0x02, count: 32),
        signedPreKeySignature: Array(repeating: 0x03, count: 64),
        preKeys: [
            OMEMOBundle.PreKeyPublic(
                id: 1, publicKey: Array(repeating: 0x04, count: 32)
            ),
            OMEMOBundle.PreKeyPublic(
                id: 2, publicKey: Array(repeating: 0x05, count: 32)
            )
        ]
    )
}

/// A real OMEMO identity with its private key material retained, so the same identity can both seed a
/// module via `configureIdentity(_:)` (`data`) and build a decryptable peer bundle via the key pairs.
struct TestOMEMOIdentity {
    let data: OMEMOModule.OMEMOIdentityData
    let identityKeyPair: OMEMOIdentityKeyPair
    let signedPreKey: OMEMOSignedPreKey
    let preKeys: [OMEMOPreKey]
}

func makeTestOMEMOIdentity(deviceID: UInt32, preKeyIDs: [UInt32]) throws -> TestOMEMOIdentity {
    let identityKeyPair = OMEMOIdentityKeyPair()
    let signedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(keyID: 1, identityKey: identityKeyPair)
    let preKeys = preKeyIDs.map { OMEMOPreKey(keyID: $0) }
    let data = OMEMOModule.OMEMOIdentityData(
        deviceID: deviceID,
        identityKeyRaw: identityKeyPair.rawRepresentation,
        signedPreKeyID: signedPreKey.keyID,
        signedPreKeyRaw: signedPreKey.rawRepresentation,
        signedPreKeySignature: signedPreKey.signature,
        preKeys: preKeys.map {
            OMEMOModule.OMEMOIdentityData.PreKeyData(keyID: $0.keyID, keyRaw: $0.rawRepresentation)
        }
    )
    return TestOMEMOIdentity(
        data: data, identityKeyPair: identityKeyPair, signedPreKey: signedPreKey, preKeys: preKeys
    )
}

/// Drives the standard handshake plus OMEMO connect where the server's own device-list ALREADY contains
/// the configured `deviceID`, so `ensureOwnDeviceInList` takes the no-publish early-return: retrieve →
/// bundle publish (no device-list publish). The own-only list means `pruneStaleBundles` has no peer
/// devices to probe, so no probe/retract scaffolding is needed. The module must have `configureIdentity`
/// called with a matching `deviceID` before this runs. Unlike `makeConnectedClient`, the mock's sent
/// buffer is NOT cleared so callers can inspect the connect-time stanza sequence.
private func makeConnectedClientWithOwnDeviceListed(
    mock: MockTransport,
    omemoModule: OMEMOModule,
    pepModule: PEPModule,
    deviceID: UInt32
) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(pepModule)
    await client.register(omemoModule)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)

    // Own device-list retrieve — return a list that ALREADY contains the configured own device ID.
    await mock.waitForSent(count: 5)
    let id5 = try await #require(extractIQID(from: mock.sentBytes[4]))
    await mock.simulateReceive(makeOwnDeviceListResultIQ(iqID: id5, devices: [deviceID]))

    // No device-list publish (own device already present) — the next stanza is the bundle publish.
    await mock.waitForSent(count: 6)
    let bundlePublishIQ = await mock.sentBytes[5]
    let id6 = try #require(extractIQID(from: bundlePublishIQ))
    await mock.simulateReceive("<iq type=\"result\" id=\"\(id6)\"/>")

    try await connectTask.value
    return client
}
