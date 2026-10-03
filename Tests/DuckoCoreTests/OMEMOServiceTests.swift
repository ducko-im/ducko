import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountJID = BareJID(localPart: "alice", domainPart: "example.com")!

@MainActor
private func makeOMEMOService(store: MockOMEMOStore) -> OMEMOService {
    OMEMOService(omemoStore: store)
}

private func makeIdentityData(deviceID: UInt32) -> OMEMOModule.OMEMOIdentityData {
    OMEMOModule.OMEMOIdentityData(
        deviceID: deviceID,
        identityKeyRaw: Array(repeating: 0xA1, count: 32),
        signedPreKeyID: 7,
        signedPreKeyRaw: Array(repeating: 0xB2, count: 32),
        signedPreKeySignature: Array(repeating: 0xC3, count: 64),
        preKeys: [
            OMEMOModule.OMEMOIdentityData.PreKeyData(
                keyID: 1, keyRaw: Array(repeating: 0xD4, count: 32)
            )
        ]
    )
}

private struct StubOMEMOIdentityProvider: OMEMOIdentityProviding {
    let identity: OMEMOModule.OMEMOIdentityData?
    let consumed: Set<UInt32>

    var ownIdentityData: OMEMOModule.OMEMOIdentityData? {
        identity
    }

    func consumedPreKeyIDs() -> Set<UInt32> {
        consumed
    }
}

// MARK: - Tests

enum OMEMOServiceTests {
    struct HandleConnectedFirstTimePersistence {
        @Test
        @MainActor
        func `returns early when identity already persisted`() async {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let identityData = makeIdentityData(deviceID: 4242)
            await store.seedFromIdentityData(identityData, accountJID: accountJID)

            let service = makeOMEMOService(store: store)
            let stub = StubOMEMOIdentityProvider(identity: identityData, consumed: [])

            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .milliseconds(100)
            )

            #expect(await store.saveIdentityCalls == 0)
            #expect(await store.savePreKeysCalls == 0)
            #expect(await store.saveSignedPreKeyCalls == 0)
        }

        @Test
        @MainActor
        func `persists identity from provider when store empty`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let identityData = makeIdentityData(deviceID: 4242)
            let stub = StubOMEMOIdentityProvider(identity: identityData, consumed: [])
            let service = makeOMEMOService(store: store)

            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .seconds(2)
            )

            #expect(await store.saveIdentityCalls == 1)
            #expect(await store.savePreKeysCalls == 1)
            #expect(await store.saveSignedPreKeyCalls == 1)

            let storedIdentity = try #require(await store.loadIdentity(for: accountJID))
            #expect(storedIdentity.deviceID == 4242)
            #expect(storedIdentity.identityKeyData == Data(identityData.identityKeyRaw))

            let storedPreKeys = try await store.loadPreKeys(for: accountJID)
            #expect(storedPreKeys.count == 1)
            #expect(storedPreKeys[0].keyID == 1)
            #expect(storedPreKeys[0].keyData == Data(identityData.preKeys[0].keyRaw))

            let storedSPK = try #require(await store.loadSignedPreKey(for: accountJID))
            #expect(storedSPK.keyID == identityData.signedPreKeyID)
            #expect(storedSPK.keyData == Data(identityData.signedPreKeyRaw))
            #expect(storedSPK.signature == Data(identityData.signedPreKeySignature))
        }

        @Test
        @MainActor
        func `marks consumed pre-keys as used`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description

            // Pre-seed identity (so the persistence branch early-returns) plus
            // three fresh pre-keys to consume against.
            await store.seedFromIdentityData(makeIdentityData(deviceID: 4242), accountJID: accountJID)
            await store.seedPreKeys([2, 3].map {
                OMEMOStoredPreKey(
                    accountJID: accountJID, keyID: $0,
                    keyData: Data(Array(repeating: UInt8($0), count: 32)),
                    isUsed: false
                )
            })

            let service = makeOMEMOService(store: store)
            let stub = StubOMEMOIdentityProvider(
                identity: makeIdentityData(deviceID: 4242),
                consumed: [1, 3]
            )

            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .milliseconds(100)
            )

            let preKeys = try await store.loadPreKeys(for: accountJID)
            let used = Set(preKeys.filter(\.isUsed).map(\.keyID))
            let unused = Set(preKeys.filter { !$0.isUsed }.map(\.keyID))
            #expect(used == [1, 3])
            #expect(unused == [2])
        }

        @Test
        @MainActor
        func `skips persistence when identity never readies`() async {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let stub = StubOMEMOIdentityProvider(identity: nil, consumed: [])
            let service = makeOMEMOService(store: store)

            let start = ContinuousClock.now
            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .milliseconds(100)
            )
            let elapsed = start.duration(to: ContinuousClock.now)

            #expect(await store.saveIdentityCalls == 0)
            #expect(await store.savePreKeysCalls == 0)
            #expect(await store.saveSignedPreKeyCalls == 0)
            // Polling exhausts at ~100 ms; allow generous slack for CI variance.
            #expect(elapsed < .milliseconds(500))
        }
    }

    struct FailedDecrypt {
        @Test
        @MainActor
        func `A message that could not be decrypted is kept as such, with no text of its own`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            let service = makeOMEMOService(store: MockOMEMOStore())
            service.setChatService(chatService)
            let accountID = UUID()
            let peer = try #require(BareJID(localPart: "peer", domainPart: "example.com"))

            await service.handleEvent(
                .omemoEncryptedMessageReceived(from: .bare(peer), decryptedBody: nil, senderDeviceID: 0, stanzaID: "omemo-bad"),
                accountID: accountID
            )

            // Stored as text, the failure would be searched, quoted and copied as if the sender had written it.
            let message = try #require(await transcripts.messages.last)
            #expect(message.isUndecryptable)
            #expect(message.body.isEmpty)
            #expect(message.previewText == ChatMessage.undecryptableText)
        }
    }

    struct EncryptionFollowsContact {
        @MainActor
        private struct Fixture {
            let service: OMEMOService
            let chatService: ChatService
            let accountService: AccountService
            let store: MockPersistenceStore
            let transcripts: MockTranscriptStore
            let accountID: UUID
            let peer: BareJID
            /// The chat with `peer` as it was stored before any message arrived.
            let seeded: Conversation

            /// Both chats are stored with encryption off, so no test depends on what a chat opened on the fly would
            /// take from this machine's "encrypt by default" preference.
            static func make() async throws -> Fixture {
                let store = MockPersistenceStore()
                let transcripts = MockTranscriptStore()
                let ownJID = try #require(BareJID(localPart: "me", domainPart: "example.com"))
                let peer = try #require(BareJID(localPart: "peer", domainPart: "example.com"))
                let account = Account(id: UUID(), jid: ownJID, isEnabled: true, connectOnLaunch: false, createdAt: Date())
                await store.addAccount(account)
                var seeded: [Conversation] = []
                for jid in [peer, ownJID] {
                    let conversation = Conversation(
                        id: UUID(), accountID: account.id, jid: jid, type: .chat,
                        isPinned: false, isMuted: false, unreadCount: 0, encryptionEnabled: false, createdAt: Date()
                    )
                    await store.addConversation(conversation)
                    seeded.append(conversation)
                }
                let accountService = makeAccountService(store: store)
                try await accountService.loadAccounts()
                let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
                let service = makeOMEMOService(store: MockOMEMOStore())
                service.setAccountService(accountService)
                service.setChatService(chatService)
                return Fixture(
                    service: service, chatService: chatService, accountService: accountService, store: store,
                    transcripts: transcripts, accountID: account.id, peer: peer, seeded: seeded[0]
                )
            }

            var ownJID: BareJID? {
                accountService.accounts.first?.jid
            }

            func receiveEncrypted(body: String?, stanzaID: String, from sender: BareJID? = nil) async {
                await service.handleEvent(
                    .omemoEncryptedMessageReceived(from: .bare(sender ?? peer), decryptedBody: body, senderDeviceID: 0, stanzaID: stanzaID),
                    accountID: accountID
                )
            }

            func conversation(with jid: BareJID) -> Conversation? {
                chatService.openConversations.first { $0.jid == jid }
            }

            var conversation: Conversation? {
                conversation(with: peer)
            }
        }

        @Test
        @MainActor
        func `A readable encrypted message switches the chat's encryption on and leaves a note`() async throws {
            let fixture = try await Fixture.make()

            await fixture.receiveEncrypted(body: "hello", stanzaID: "omemo-1")
            await fixture.receiveEncrypted(body: "again", stanzaID: "omemo-2")

            let conversation = try #require(fixture.conversation)
            #expect(conversation.encryptionEnabled)
            // One note for the switch, none for the messages that follow it.
            let notes = await fixture.transcripts.notes
            #expect(notes.map(\.kind) == [.encryptionEnabledByContact])
            #expect(notes.first?.conversationID == conversation.id)
        }

        @Test
        @MainActor
        func `Encrypted messages handled at once leave one note between them`() async throws {
            let fixture = try await Fixture.make()

            // Each event is handled in a task of its own, as the app dispatches them.
            await withTaskGroup(of: Void.self) { group in
                for index in 1 ... 3 {
                    group.addTask { await fixture.receiveEncrypted(body: "hello", stanzaID: "omemo-\(index)") }
                }
            }

            #expect(try #require(fixture.conversation).encryptionEnabled)
            #expect(await fixture.transcripts.notes.count == 1)
        }

        @Test
        @MainActor
        func `A second switch started while the first is being stored leaves no note of its own`() async throws {
            let fixture = try await Fixture.make()
            try await fixture.chatService.loadConversations(for: fixture.accountID)
            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await fixture.store.installConversationWriteGate(entered: entered, release: release)

            let first = Task { @MainActor in
                await fixture.chatService.enableEncryptionForContact(in: fixture.seeded.id, accountID: fixture.accountID)
            }
            await entered.wait()
            await fixture.chatService.enableEncryptionForContact(in: fixture.seeded.id, accountID: fixture.accountID)
            await release.signal()
            await first.value

            #expect(try #require(fixture.conversation).encryptionEnabled)
            #expect(await fixture.transcripts.notes.count == 1)
        }

        @Test
        @MainActor
        func `A switch-off stored a moment ago holds against a contact's encrypted message`() async throws {
            let fixture = try await Fixture.make()
            try await fixture.chatService.loadConversations(for: fixture.accountID)
            // The user's switch-off is stored, and the copy of the chat the service holds does not show it yet.
            try await fixture.store.updateConversation(fixture.seeded.id) { $0.encryptionOptedOut = true }
            try #require(fixture.conversation?.encryptionOptedOut == false)

            await fixture.chatService.enableEncryptionForContact(in: fixture.seeded.id, accountID: fixture.accountID)

            let conversation = try #require(fixture.conversation)
            #expect(!conversation.encryptionEnabled)
            #expect(conversation.encryptionOptedOut)
            #expect(await fixture.transcripts.notes.isEmpty)
        }

        @Test
        @MainActor
        func `A room's encryption is not switched on by an encrypted message`() async throws {
            let fixture = try await Fixture.make()
            let room = try Conversation(
                id: UUID(), accountID: fixture.accountID, jid: #require(BareJID(localPart: "room", domainPart: "conference.example.com")),
                type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0, encryptionEnabled: false, createdAt: Date()
            )
            await fixture.store.addConversation(room)
            try await fixture.chatService.loadConversations(for: fixture.accountID)

            await fixture.chatService.enableEncryptionForContact(in: room.id, accountID: fixture.accountID)

            #expect(fixture.chatService.openConversations.first { $0.id == room.id }?.encryptionEnabled == false)
            #expect(await fixture.transcripts.notes.isEmpty)
        }

        @Test
        @MainActor
        func `A message handled with an older copy of the chat does not switch its encryption back off`() async throws {
            let fixture = try await Fixture.make()
            await fixture.receiveEncrypted(body: "hello", stanzaID: "omemo-1")
            // Armed: the switch is stored, so the older copy below disagrees with it.
            try #require(fixture.conversation?.encryptionEnabled == true)

            let late = ChatMessage(
                id: UUID(), conversationID: fixture.seeded.id, fromJID: fixture.peer.description, body: "late",
                timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "chat"
            )
            await fixture.chatService.persistEncryptedMessage(late, in: fixture.seeded, accountID: fixture.accountID)

            let conversation = try #require(fixture.conversation)
            #expect(conversation.encryptionEnabled)
            #expect(conversation.unreadCount == 2)
        }

        @Test
        @MainActor
        func `Switching a chat's encryption or muting it writes that alone, not the copy of the chat it started from`() async throws {
            let fixture = try await Fixture.make()
            try await fixture.chatService.loadConversations(for: fixture.accountID)
            // Armed: the service holds a copy of the chat, which what is stored next makes the older one.
            try #require(fixture.conversation?.unreadCount == 0)

            try await fixture.store.updateConversation(fixture.seeded.id) { $0.unreadCount = 3 }
            try await fixture.chatService.setEncryptionEnabled(true, for: fixture.seeded.id, accountID: fixture.accountID)
            #expect(try #require(fixture.conversation).encryptionEnabled)
            #expect(fixture.conversation?.unreadCount == 3)

            try await fixture.store.updateConversation(fixture.seeded.id) { $0.unreadCount = 5 }
            try await fixture.chatService.toggleMute(conversationID: fixture.seeded.id, accountID: fixture.accountID)
            #expect(try #require(fixture.conversation).isMuted)
            #expect(fixture.conversation?.unreadCount == 5)
        }

        @Test
        @MainActor
        func `A message that could not be decrypted leaves encryption off`() async throws {
            let fixture = try await Fixture.make()

            await fixture.receiveEncrypted(body: nil, stanzaID: "omemo-bad")

            #expect(try #require(fixture.conversation).encryptionEnabled == false)
            #expect(await fixture.transcripts.notes.isEmpty)
        }

        @Test
        @MainActor
        func `An echo of the user's own encrypted message leaves encryption off`() async throws {
            let fixture = try await Fixture.make()

            let ownJID = try #require(fixture.ownJID)

            await fixture.receiveEncrypted(body: "mine", stanzaID: "omemo-own", from: ownJID)

            // Armed: the echo was stored, as an outgoing message.
            #expect(await fixture.transcripts.messages.last?.isOutgoing == true)
            #expect(try #require(fixture.conversation(with: ownJID)).encryptionEnabled == false)
            #expect(await fixture.transcripts.notes.isEmpty)
        }

        @Test
        @MainActor
        func `Encryption the user switched off stays off`() async throws {
            let fixture = try await Fixture.make()
            await fixture.receiveEncrypted(body: "hello", stanzaID: "omemo-1")
            let conversationID = try #require(fixture.conversation).id
            try await fixture.chatService.setEncryptionEnabled(false, for: conversationID, accountID: fixture.accountID)

            await fixture.receiveEncrypted(body: "again", stanzaID: "omemo-2")

            #expect(try #require(fixture.conversation).encryptionEnabled == false)
            #expect(await fixture.transcripts.notes.count == 1)
        }
    }

    /// Locks the production `OMEMOService` conformance to
    /// `SeenDeviceClassificationProviding` — the per-device classification
    /// cache must persist across reads, stay isolated per account, lazy-load
    /// from the store on first read, and coalesce concurrent first-loads
    /// onto a single store call. The pruning unit tests in DuckoXMPP use a
    /// stub provider; these tests prove the real production wiring keeps
    /// its data correctly.
    struct SeenDeviceClassificationProvider {
        @Test
        @MainActor
        func `empty by default; merge round-trips per account`() async {
            let store = MockOMEMOStore()
            let service = makeOMEMOService(store: store)
            let acctA = UUID().uuidString
            let accountJID = testAccountJID.description
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)

            let empty = await service.loadSeenDevices(accountID: acctA)
            #expect(empty.isEmpty)

            let record = SeenDeviceRecord(
                deviceID: 42, lastClassification: .healthy,
                staleStreak: 0, hasObservedHealthy: true
            )
            await service.mergeSeenDevices([42: record], accountID: acctA)
            let read = await service.loadSeenDevices(accountID: acctA)
            #expect(read[42] == record)
        }

        @Test
        @MainActor
        func `lazy-loads from store on first read; second read is in-memory`() async {
            let store = MockOMEMOStore()
            let acctA = UUID().uuidString
            let accountJID = testAccountJID.description
            await store.seedSeenDevices(
                [OMEMOStoredSeenDevice(
                    accountJID: accountJID, deviceID: 7,
                    classification: BundleClassification.healthy.rawValue,
                    staleStreak: 0, hasObservedHealthy: true
                )],
                for: accountJID
            )

            let service = makeOMEMOService(store: store)
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)

            _ = await service.loadSeenDevices(accountID: acctA)
            #expect(await store.loadSeenDevicesCalls == 1)
            _ = await service.loadSeenDevices(accountID: acctA)
            // Second read hits the in-memory cache, not the store.
            #expect(await store.loadSeenDevicesCalls == 1)
        }

        @Test
        @MainActor
        func `unrecognized classification raw values are dropped`() async {
            let store = MockOMEMOStore()
            let acctA = UUID().uuidString
            let accountJID = testAccountJID.description
            await store.seedSeenDevices(
                [OMEMOStoredSeenDevice(
                    accountJID: accountJID, deviceID: 7,
                    classification: "future-unknown-value",
                    staleStreak: 1, hasObservedHealthy: true
                )],
                for: accountJID
            )

            let service = makeOMEMOService(store: store)
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)

            let loaded = await service.loadSeenDevices(accountID: acctA)
            // Forward-compat: the unknown row is silently dropped at load time.
            #expect(loaded[7] == nil)
        }

        @Test
        @MainActor
        func `replaceSeenDevices replaces in-memory and store state`() async {
            let store = MockOMEMOStore()
            let acctA = UUID().uuidString
            let accountJID = testAccountJID.description
            let service = makeOMEMOService(store: store)
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)
            await service.mergeSeenDevices(
                [
                    1: SeenDeviceRecord(deviceID: 1, lastClassification: .stale, staleStreak: 1, hasObservedHealthy: true),
                    2: SeenDeviceRecord(deviceID: 2, lastClassification: .healthy, staleStreak: 0, hasObservedHealthy: true)
                ],
                accountID: acctA
            )
            await service.replaceSeenDevices(
                [9: SeenDeviceRecord(deviceID: 9, lastClassification: .healthy, staleStreak: 0, hasObservedHealthy: true)],
                accountID: acctA
            )
            let read = await service.loadSeenDevices(accountID: acctA)
            #expect(read.count == 1)
            #expect(read[9]?.lastClassification == .healthy)
            #expect(read[1] == nil)
            #expect(read[2] == nil)
        }

        @Test
        @MainActor
        func `purgeSeenDeviceClassifications clears in-memory and pending state`() async {
            let store = MockOMEMOStore()
            let id = UUID()
            let acctA = id.uuidString
            let accountJID = testAccountJID.description
            let service = makeOMEMOService(store: store)
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)

            await service.mergeSeenDevices(
                [42: SeenDeviceRecord(deviceID: 42, lastClassification: .healthy, staleStreak: 0, hasObservedHealthy: true)],
                accountID: acctA
            )
            #expect(await service.loadSeenDevices(accountID: acctA).count == 1)

            service.purgeSeenDeviceClassifications(accountID: id)
            // After purge, the accountJID mapping is gone so we re-install
            // it before re-reading; the cache is empty by contract.
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)
            #expect(await service.loadSeenDevices(accountID: acctA).isEmpty)
        }

        @Test
        @MainActor
        func `purgeOrphanDeviceRecords deletes one trust and session per device`() async throws {
            let store = MockOMEMOStore()
            let acctA = UUID().uuidString
            let accountJID = testAccountJID.description
            let service = makeOMEMOService(store: store)
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)

            try await service.purgeOrphanDeviceRecords(deviceIDs: [10, 20, 30], accountID: acctA)
            #expect(await store.deleteTrustCalls == 3)
            #expect(await store.deleteSessionCalls == 3)
        }
    }

    /// Pins `MockOMEMOStore`'s upsert behavior so future mock-only edits can't
    /// silently drift back to append-on-write.
    struct MockStoreSemantics {
        @Test
        @MainActor
        func `saveSession upserts by peer JID and device ID`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let peerJID = "peer@example.com"
            let deviceID: UInt32 = 42

            let original = OMEMOStoredSession(
                accountJID: accountJID, peerJID: peerJID, peerDeviceID: deviceID,
                sessionData: Data([0xAA]), associatedData: Data([0xBB])
            )
            let replacement = OMEMOStoredSession(
                accountJID: accountJID, peerJID: peerJID, peerDeviceID: deviceID,
                sessionData: Data([0xCC]), associatedData: Data([0xDD])
            )
            try await store.saveSession(original)
            try await store.saveSession(replacement)

            let sessions = try await store.loadSessions(for: accountJID)
            #expect(sessions.count == 1)
            #expect(sessions.first?.sessionData == Data([0xCC]))
            #expect(sessions.first?.associatedData == Data([0xDD]))
        }

        @Test
        @MainActor
        func `saveTrust upserts by peer JID and device ID`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let peerJID = "peer@example.com"
            let deviceID: UInt32 = 42

            try await store.saveTrust(OMEMOTrust(
                accountJID: accountJID, peerJID: peerJID,
                deviceID: deviceID, fingerprint: "", trustLevel: .undecided
            ))
            try await store.saveTrust(OMEMOTrust(
                accountJID: accountJID, peerJID: peerJID,
                deviceID: deviceID, fingerprint: "abcd", trustLevel: .verified
            ))

            let devices = try await store.loadAllDevices(for: peerJID, accountJID: accountJID)
            #expect(devices.count == 1)
            #expect(devices.first?.fingerprint == "abcd")
            #expect(devices.first?.trustLevel == .verified)
        }
    }
}
