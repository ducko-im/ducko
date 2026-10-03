// Split candidate.
// swiftlint:disable file_length
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

enum FileTransferServiceTests { // swiftlint:disable:this type_body_length
    private static let testAccountID = UUID()

    private static func makeConversation(type: Conversation.ConversationType = .chat) -> Conversation {
        Conversation(
            id: UUID(),
            accountID: UUID(),
            jid: .parse("friend@example.com")!,
            type: type,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
    }

    private static func isOfferNotFound(_ error: FileTransferService.FileTransferError?) -> Bool {
        if case .offerNotFound? = error { true } else { false }
    }

    @MainActor
    private static func failureReason(_ service: FileTransferService, sid: String) -> String? {
        guard case let .failed(reason) = service.activeTransfers.first(where: { $0.sid == sid })?.state else { return nil }
        return reason
    }

    @MainActor
    private static func failureReason(_ service: FileTransferService, rowID: UUID) -> String? {
        guard case let .failed(reason) = service.activeTransfers.first(where: { $0.id == rowID })?.state else { return nil }
        return reason
    }

    /// Puts an accepted incoming Jingle transfer's row in `service` under `sid` and returns its id. A Jingle offer only
    /// gets a row once the user accepts it, which needs a session, so the rules that act on an existing row start here.
    @MainActor
    @discardableResult
    private static func seedJingleRow(_ service: FileTransferService, sid: String, accountID: UUID = testAccountID) -> UUID {
        let id = UUID()
        service.registerTransferForTesting(.init(
            id: id, accountID: accountID, fileName: "file.bin", fileSize: 1, state: .connectingTransport, method: .jingle,
            direction: .incoming, sid: sid
        ))
        return id
    }

    /// Delivers an OOB offer with stanza id `id` to `service`, which gives it a waiting row.
    @MainActor
    private static func seedOOBOffer(
        _ service: FileTransferService, id: String, offerID: String, accountID: UUID = testAccountID
    ) throws {
        let peer = try #require(FullJID.parse("sender@example.com/res"))
        let offer = OOBIQOffer(offerID: offerID, id: id, from: .full(peer), url: "https://example.com/file.bin", desc: nil)
        service.handleJingleEvent(.oobIQOfferReceived(offer), accountID: accountID)
    }

    @MainActor
    struct Initialization {
        @Test
        func `Starts with empty active transfers`() {
            let service = FileTransferService()
            #expect(service.activeTransfers.isEmpty)
        }
    }

    @MainActor
    struct SendFileErrors {
        @Test
        func `Throws fileReadFailed for missing file`() async throws {
            let service = FileTransferService()

            let conversation = makeConversation()

            let fakeURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID()).txt")
            do {
                try await service.sendFile(url: fakeURL, in: conversation, accountID: testAccountID)
                Issue.record("Expected fileReadFailed error")
            } catch let error as FileTransferService.FileTransferError {
                if case .fileReadFailed = error {
                    // Expected
                } else {
                    Issue.record("Expected fileReadFailed, got \(error)")
                }
            }
        }
    }

    @MainActor
    struct SendFileNoClient {
        @Test
        func `Throws noClient when no account service is set`() async throws {
            let service = FileTransferService()

            let conversation = makeConversation()

            // Create a real temp file
            try await withTemporaryDirectory { directory in
                let tempURL = directory.appendingPathComponent("test.txt")
                try "hello".write(to: tempURL, atomically: true, encoding: .utf8)

                do {
                    try await service.sendFile(url: tempURL, in: conversation, accountID: testAccountID)
                    Issue.record("Expected noClient error")
                } catch let error as FileTransferService.FileTransferError {
                    if case .noClient = error {
                        // Expected
                    } else {
                        Issue.record("Expected noClient, got \(error)")
                    }
                }
            }
        }
    }

    @MainActor
    struct DirectSend {
        private static func isUnavailable(_ error: FileTransferService.FileTransferError?) -> Bool {
            if case .directTransferUnavailable? = error { true } else { false }
        }

        @Test
        func `A direct send with no session to go to fails on its own row and is not uploaded`() async throws {
            let transcripts = MockTranscriptStore()
            let chatService = ChatService(store: MockPersistenceStore(), transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            let service = FileTransferService()
            service.setChatService(chatService)
            let conversation = makeConversation()

            try await withTemporaryDirectory { directory in
                let fileURL = directory.appendingPathComponent("notes.txt")
                try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

                let error = await #expect(throws: FileTransferService.FileTransferError.self) {
                    try await service.sendFile(url: fileURL, in: conversation, accountID: testAccountID, method: .jingle)
                }
                #expect(Self.isUnavailable(error))

                // The file has its row in the chat, carrying the reason, and the transfer under the same id failed.
                let stored = try #require(await transcripts.messages.first)
                let row = try #require(await transcripts.fetchMessages(for: stored.conversationID, before: nil, limit: 10).first)
                #expect(row.isOutgoing)
                #expect(row.attachments.first?.localFileURL == fileURL)
                #expect(row.errorText == "The contact has no device online that can receive files directly")
                #expect(!row.isDelivered)
                #expect(service.activeTransfers.map(\.id) == [row.id])
                #expect(failureReason(service, rowID: row.id) == row.errorText)
            }
        }

        @Test
        func `A room has no one device to send to directly`() async throws {
            let transcripts = MockTranscriptStore()
            let chatService = ChatService(store: MockPersistenceStore(), transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            let service = FileTransferService()
            service.setChatService(chatService)

            try await withTemporaryDirectory { directory in
                let fileURL = directory.appendingPathComponent("notes.txt")
                try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

                let error = await #expect(throws: FileTransferService.FileTransferError.self) {
                    try await service.sendFile(
                        url: fileURL, in: makeConversation(type: .groupchat), accountID: testAccountID, method: .jingle
                    )
                }
                #expect(Self.isUnavailable(error))
                #expect(await transcripts.messages.isEmpty)
                #expect(service.activeTransfers.isEmpty)
            }
        }

        @Test(arguments: [nil, "The peer declined the transfer"])
        func `A directly sent file's row keeps how the transfer ended`(failure: String?) async throws {
            let transcripts = MockTranscriptStore()
            let chatService = ChatService(store: MockPersistenceStore(), transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            let conversation = makeConversation()
            let rowID = UUID()
            let file = DuckoCore.Attachment.locallySaved(
                id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/notes.txt"), mimeType: "text/plain", fileSize: 5
            )
            let conversationID = try await chatService.recordSentFile(file, id: rowID, to: conversation.jid, accountID: testAccountID)

            await chatService.recordSentFileOutcome(messageID: rowID, in: conversationID, failure: failure)

            let row = try #require(await chatService.loadMessages(for: conversationID).first)
            #expect(row.id == rowID)
            #expect(row.isDelivered == (failure == nil))
            #expect(row.errorText == failure)
        }

        struct SessionChoice {
            /// The contact's online sessions, in the order the contact shows them.
            let online: [String]
            let capable: [String]
            let locked: String?
            let expected: String?
        }

        @Test(arguments: [
            // The session the contact last wrote from wins when it takes direct transfers.
            SessionChoice(online: ["phone", "laptop"], capable: ["phone", "laptop"], locked: "laptop", expected: "laptop"),
            // One that does not is passed over for the first shown session that does.
            SessionChoice(online: ["phone", "laptop"], capable: ["phone"], locked: "laptop", expected: "phone"),
            SessionChoice(online: ["phone", "laptop", "tablet"], capable: ["laptop", "tablet"], locked: nil, expected: "laptop"),
            SessionChoice(online: ["phone", "laptop"], capable: [], locked: "phone", expected: nil),
            SessionChoice(online: [], capable: [], locked: nil, expected: nil)
        ])
        func `A direct send goes to the session last written from, else the first shown one that takes it`(choice: SessionChoice) throws {
            let contact = try #require(BareJID.parse("friend@example.com"))
            let sessions = choice.online.compactMap { FullJID(bareJID: contact, resourcePart: $0) }

            let chosen = DirectTransferResolver.chooseSession(among: sessions, lockedResource: choice.locked) {
                choice.capable.contains($0.resourcePart)
            }

            #expect(chosen?.resourcePart == choice.expected)
        }
    }

    /// Which of a contact's sessions a direct send goes to, through a connected client whose peer sessions answer the
    /// question the way the test sets them up to.
    @MainActor
    struct DirectTransferTargets {
        private static let contact = BareJID(localPart: "friend", domainPart: "example.com")!

        private enum Answer {
            /// Takes file transfers.
            case capable
            /// Answers without the file transfer feature.
            case incapable
            /// Answers with an error.
            case refusing
            /// Never answers.
            case silent
        }

        @MainActor
        private struct Harness {
            let accountService: AccountService
            let chatService: ChatService
            let presenceService: PresenceService
            let service: FileTransferService
            let transport: MockTransport
            let accountID: UUID
            let connectTask: Task<Void, any Error>

            func deliver(_ type: XMPPPresence.PresenceType? = nil, from resource: String?, priority: Int = 0) async throws {
                var presence = XMPPPresence(type: type)
                presence.priority = priority
                let contact = DirectTransferTargets.contact
                let from: JID = if let resource {
                    try .full(#require(FullJID(bareJID: contact, resourcePart: resource)))
                } else {
                    .bare(contact)
                }
                let event = XMPPEvent.presenceUpdated(from: from, presence: presence)
                await presenceService.handleEvent(event, accountID: accountID)
                service.handleJingleEvent(event, accountID: accountID)
            }

            var canSendDirectly: Bool {
                service.canSendDirectly(toJIDString: DirectTransferTargets.contact.description, accountID: accountID)
            }

            func refresh() async {
                await service.refreshDirectTransferSupport(forJIDString: DirectTransferTargets.contact.description, accountID: accountID)
            }

            /// How often `resource` was asked whether it takes file transfers.
            func questions(to resource: String) async -> Int {
                await transport.sentBytes.count { bytes in
                    let stanza = String(decoding: bytes, as: UTF8.self)
                    return stanza.contains("disco#info") && stanza.contains("to=\"\(DirectTransferTargets.contact)/\(resource)\"")
                }
            }
        }

        private static func connect(_ answers: [String: Answer]) async throws -> Harness {
            let store = MockPersistenceStore()
            let account = try Account(
                id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date()
            )
            await store.addAccount(account)
            let transport = MockTransport()
            await transport.autoReply { stanza in
                guard let id = stanza.firstMatch(of: /\sid=["']([^"']+)["']/)?.output.1,
                      let to = stanza.firstMatch(of: /\sto=["']([^"']+)["']/)?.output.1 else { return nil }
                if stanza.contains("disco#items") {
                    return "<iq type='result' id='\(id)' from='\(to)'><query xmlns='http://jabber.org/protocol/disco#items'/></iq>"
                }
                guard stanza.contains("disco#info"), let resource = to.split(separator: "/").dropFirst().first else { return nil }
                switch answers[String(resource)] {
                case .capable?:
                    return "<iq type='result' id='\(id)' from='\(to)'><query xmlns='http://jabber.org/protocol/disco#info'>"
                        + "<feature var='urn:xmpp:jingle:1'/><feature var='urn:xmpp:jingle:apps:file-transfer:5'/></query></iq>"
                case .incapable?:
                    return "<iq type='result' id='\(id)' from='\(to)'><query xmlns='http://jabber.org/protocol/disco#info'>"
                        + "<feature var='urn:xmpp:jingle:1'/></query></iq>"
                case .refusing?:
                    return "<iq type='error' id='\(id)' from='\(to)'><error type='cancel'>"
                        + "<service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
                case .silent?, nil:
                    return nil
                }
            }
            let accountService = makeAccountService(
                store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [ServiceDiscoveryModule(), JingleModule()])
            )
            try await accountService.loadAccounts()
            let chatService = ChatService(store: store, transcripts: MockTranscriptStore(), filterPipeline: MessageFilterPipeline())
            let presenceService = makePresenceService()
            let service = FileTransferService()
            service.setAccountService(accountService)
            service.setChatService(chatService)
            service.setPresenceService(presenceService)
            let (_, connectTask) = try await driveMockConnect(accountService, accountID: account.id, transport: transport)
            return Harness(
                accountService: accountService, chatService: chatService, presenceService: presenceService, service: service,
                transport: transport, accountID: account.id, connectTask: connectTask
            )
        }

        private static func tearDown(_ harness: Harness) async {
            harness.connectTask.cancel()
            await harness.accountService.disconnectAll()
        }

        /// Starts a direct send to the contact with no session named and returns the session the offer went to.
        private static func offeredSession(_ harness: Harness) async throws -> String? {
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appendingPathComponent("notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let conversation = try await harness.chatService.openConversation(for: contact, accountID: harness.accountID)
                try await harness.service.startDirectTransfer(url: fileURL, in: conversation, accountID: harness.accountID)
                let transport = harness.transport
                let offer = OfferBox()
                let outcome = try await boundedOutcome {
                    await offer.set(transport.waitForSent { $0.contains("session-initiate") })
                }
                guard outcome != nil, let stanza = await offer.stanza else { return nil }
                return stanza.firstMatch(of: /\sto=["'][^"'\/]+\/([^"']+)["']/).map { String($0.output.1) }
            }
        }

        private actor OfferBox {
            var stanza: String?

            func set(_ stanza: String?) {
                self.stanza = stanza
            }
        }

        @Test
        func `Only a session that says it takes file transfers can be sent to directly`() async throws {
            let harness = try await Self.connect(["phone": .incapable, "laptop": .capable])
            // The phone is the session the contact shows first.
            try await harness.deliver(from: "phone", priority: 5)
            #expect(!harness.canSendDirectly)

            await harness.refresh()
            // Armed: the phone was asked and its answer is in.
            #expect(await harness.questions(to: "phone") == 1)
            #expect(!harness.canSendDirectly)

            try await harness.deliver(from: "laptop")
            await harness.refresh()
            #expect(harness.canSendDirectly)
            #expect(try await Self.offeredSession(harness) == "laptop")
            await Self.tearDown(harness)
        }

        @Test
        func `A session that answers with an error is taken as a no and not asked again`() async throws {
            let harness = try await Self.connect(["phone": .refusing])
            try await harness.deliver(from: "phone")

            await harness.refresh()
            await harness.refresh()

            #expect(await harness.questions(to: "phone") == 1)
            #expect(!harness.canSendDirectly)
            await Self.tearDown(harness)
        }

        @Test(arguments: [true, false])
        func `A session that went offline is asked again when it comes back`(wholeContact: Bool) async throws {
            let harness = try await Self.connect(["laptop": .capable])
            try await harness.deliver(from: "laptop")
            await harness.refresh()
            try #require(harness.canSendDirectly)

            // Unavailable from the bare JID speaks for every session the contact had.
            try await harness.deliver(.unavailable, from: wholeContact ? nil : "laptop")
            try await harness.deliver(from: "laptop")
            // Whatever runs under the name now has not answered yet.
            #expect(!harness.canSendDirectly)

            await harness.refresh()
            #expect(harness.canSendDirectly)
            #expect(await harness.questions(to: "laptop") == 2)
            await Self.tearDown(harness)
        }

        @Test
        func `Answers outlast a dropped connection and end with a new session`() async throws {
            let harness = try await Self.connect(["laptop": .capable])
            try await harness.deliver(from: "laptop")
            await harness.refresh()
            try #require(harness.canSendDirectly)

            // A dropped connection may resume, with no presence sent again.
            harness.service.handleJingleEvent(.disconnected(.connectionLost("The connection was lost")), accountID: harness.accountID)
            #expect(harness.canSendDirectly)

            let ownSession = try #require(FullJID.parse("\(testJIDString)/ducko"))
            harness.service.handleJingleEvent(.connected(ownSession), accountID: harness.accountID)
            #expect(!harness.canSendDirectly)
            await Self.tearDown(harness)
        }

        @Test
        func `A session already known to take the file is offered it without waiting on one that is silent`() async throws {
            let harness = try await Self.connect(["laptop": .capable, "tablet": .silent])
            try await harness.deliver(from: "laptop")
            await harness.refresh()
            try #require(harness.canSendDirectly)
            try await harness.deliver(from: "tablet", priority: 5)

            #expect(try await Self.offeredSession(harness) == "laptop")
            #expect(await harness.questions(to: "tablet") == 0)
            await Self.tearDown(harness)
        }

        @Test
        func `A direct send asks the contact's sessions itself when none has been asked yet`() async throws {
            let harness = try await Self.connect(["laptop": .capable])
            try await harness.deliver(from: "laptop")
            try #require(!harness.canSendDirectly)

            #expect(try await Self.offeredSession(harness) == "laptop")
            #expect(await harness.questions(to: "laptop") == 1)
            await Self.tearDown(harness)
        }

        @Test
        func `A direct send cut off by the app quitting leaves its row without an outcome`() async throws {
            let harness = try await Self.connect(["laptop": .capable])
            try await harness.deliver(from: "laptop")
            await harness.refresh()
            // Armed: the offer is out, and the contact has not answered it.
            #expect(try await Self.offeredSession(harness) == "laptop")

            let tasks = harness.service.takePendingTasks()
            for task in tasks {
                task.cancel()
            }
            let outcome = try await boundedOutcome {
                for task in tasks {
                    await task.value
                }
            }
            try #require(outcome != nil)

            let conversation = try await harness.chatService.openConversation(for: Self.contact, accountID: harness.accountID)
            let row = try #require(await harness.chatService.loadMessages(for: conversation.id).last)
            #expect(row.errorText == nil)
            #expect(!row.isDelivered)
            await Self.tearDown(harness)
        }

        @Test
        func `The session the contact last wrote from is the one a direct send goes to`() async throws {
            let harness = try await Self.connect(["laptop": .capable, "tablet": .capable])
            // The laptop is the session the contact shows first.
            try await harness.deliver(from: "laptop", priority: 5)
            try await harness.deliver(from: "tablet")
            await harness.refresh()
            var message = try XMPPMessage(type: .chat, to: .bare(#require(BareJID.parse(testJIDString))), id: "in-1")
            message.from = try .full(#require(FullJID(bareJID: Self.contact, resourcePart: "tablet")))
            message.body = "hi"
            await harness.chatService.handleEvent(.messageReceived(message), accountID: harness.accountID)

            #expect(try await Self.offeredSession(harness) == "tablet")
            await Self.tearDown(harness)
        }

        @Test
        func `At most eight of a contact's sessions are asked at a time`() async throws {
            let resources = (1 ... 9).map { "device-\($0)" }
            let harness = try await Self.connect(Dictionary(uniqueKeysWithValues: resources.map { ($0, Answer.capable) }))
            for resource in resources {
                try await harness.deliver(from: resource)
            }
            func questions() async -> Int {
                var count = 0
                for resource in resources {
                    count += await harness.questions(to: resource)
                }
                return count
            }

            await harness.refresh()
            #expect(await questions() == 8)

            await harness.refresh()
            #expect(await questions() == 9)
            await Self.tearDown(harness)
        }

        @Test
        func `A question still waiting for its answer is not sent again, even when its caller is cancelled`() async throws {
            let harness = try await Self.connect(["tablet": .silent])
            try await harness.deliver(from: "tablet")
            let first = Task { await harness.refresh() }
            _ = await harness.transport.waitForSent { $0.contains("disco#info") && $0.contains("/tablet") }

            // A view asks from a task that ends like this whenever the contact's sessions change. Either refresh goes
            // on waiting for the answer, so the waits here only give a question that did get sent again the time to go
            // out.
            first.cancel()
            _ = try await boundedOutcome(timeout: .milliseconds(300)) { await first.value }
            let second = Task { await harness.refresh() }
            _ = try await boundedOutcome(timeout: .milliseconds(300)) { await second.value }

            #expect(await harness.questions(to: "tablet") == 1)
            await Self.tearDown(harness)
            await first.value
            await second.value
        }

        /// The capable answer to the question a refresh put to `resource`, as the session sends it.
        private static func capableAnswer(to question: String, from resource: String) throws -> String {
            let id = try #require(question.firstMatch(of: /\sid=["']([^"']+)["']/)?.output.1)
            return "<iq type='result' id='\(id)' from='\(contact)/\(resource)'><query xmlns='http://jabber.org/protocol/disco#info'>"
                + "<feature var='urn:xmpp:jingle:1'/><feature var='urn:xmpp:jingle:apps:file-transfer:5'/></query></iq>"
        }

        @Test
        func `A direct send waits for the answer to a question that is already on its way`() async throws {
            let harness = try await Self.connect(["tablet": .silent])
            try await harness.deliver(from: "tablet")
            let asking = Task { await harness.refresh() }
            let question = try #require(await harness.transport.waitForSent { $0.contains("disco#info") && $0.contains("/tablet") })

            let sending = Task { try await Self.offeredSession(harness) }
            // The send cannot have its session yet. The wait gives one that gave up at once the time to do so.
            _ = try await boundedOutcome(timeout: .milliseconds(300)) { _ = try await sending.value }
            try await harness.transport.simulateReceive(Self.capableAnswer(to: question, from: "tablet"))

            #expect(try await sending.value == "tablet")
            #expect(await harness.questions(to: "tablet") == 1)
            await asking.value
            await Self.tearDown(harness)
        }

        @Test
        func `A session whose question got no answer is asked again`() async throws {
            let harness = try await Self.connect(["laptop": .capable])
            try await harness.deliver(from: "laptop")
            await harness.transport.failNextSend(matching: "disco#info", error: XMPPClientError.sendFailed("The connection was closed"))

            await harness.refresh()
            // Armed: the first question never went out, and that is not taken as a no.
            try #require(await harness.questions(to: "laptop") == 0)
            #expect(!harness.canSendDirectly)

            await harness.refresh()
            #expect(harness.canSendDirectly)
            await Self.tearDown(harness)
        }

        @Test
        func `An answer to a question asked before the session went offline is not kept for what came back`() async throws {
            let harness = try await Self.connect(["tablet": .silent])
            try await harness.deliver(from: "tablet")
            let first = Task { await harness.refresh() }
            let question = try #require(await harness.transport.waitForSent { $0.contains("disco#info") && $0.contains("/tablet") })

            try await harness.deliver(.unavailable, from: "tablet")
            try await harness.deliver(from: "tablet")
            // The old session's answer arrives only now.
            try await harness.transport.simulateReceive(Self.capableAnswer(to: question, from: "tablet"))
            await first.value

            #expect(!harness.canSendDirectly)
            await Self.tearDown(harness)
        }
    }

    @MainActor
    struct ActiveTransferTracking {
        @Test
        func `Transfer appears in activeTransfers during send attempt`() async throws {
            let service = FileTransferService()

            let conversation = makeConversation()

            try await withTemporaryDirectory { directory in
                let tempURL = directory.appendingPathComponent("test.txt")
                try "test content".write(to: tempURL, atomically: true, encoding: .utf8)

                // Will fail at noClient, but transfer should still be tracked
                _ = try? await service.sendFile(url: tempURL, in: conversation, accountID: testAccountID)

                #expect(service.activeTransfers.count == 1)
                let transfer = service.activeTransfers[0]
                #expect(transfer.fileName == tempURL.lastPathComponent)
                if case .failed = transfer.state {
                    // Expected — failed due to no client
                } else {
                    Issue.record("Expected failed state, got \(transfer.state)")
                }
            }
        }
    }

    @MainActor
    struct TransferStateJingleCases {
        @Test
        func `Jingle transfer states can be pattern-matched`() {
            let states: [FileTransferService.TransferState] = [
                .negotiating,
                .connectingTransport,
                .transferring(progress: 0.5),
                .awaitingAcceptance,
                .completedTransfer
            ]

            for transferState in states {
                switch transferState {
                case .negotiating, .connectingTransport, .awaitingAcceptance, .completedTransfer, .received:
                    break
                case let .transferring(progress):
                    #expect(progress == 0.5)
                case .requestingSlot, .uploading, .completed, .failed:
                    Issue.record("Unexpected HTTP state in Jingle test")
                }
            }
        }
    }

    @MainActor
    struct IncomingOfferTracking {
        @Test
        func `handleJingleEvent tracks incoming file offers`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(
                offerID: "test-offer",
                sid: "test-sid",
                from: peer,
                fileName: "document.pdf",
                fileSize: 5000,
                mediaType: "application/pdf"
            )

            var announced: [FileTransferService.IncomingFileOffer] = []
            service.onIncomingOffer = { announced.append($0) }

            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: testAccountID)

            #expect(service.incomingOffers.count == 1)
            #expect(service.incomingOffers[0].offer.sid == "test-sid")
            #expect(service.incomingOffers[0].offer.fileName == "document.pdf")
            #expect(service.incomingOffers[0].accountID == testAccountID)

            // The row belongs to the accepted transfer, so an offer still waiting on the user has none.
            #expect(service.activeTransfers.isEmpty)

            // Each offer, of either kind, is announced once as the banner will show it, so that one arriving while no
            // chat window is open can still be noticed.
            try seedOOBOffer(service, id: "oob-1", offerID: "link-offer")
            #expect(announced.map(\.offerID) == ["test-offer", "link-offer"])
            #expect(announced.map(\.fileName) == ["document.pdf", "file.bin"])
            #expect(announced.map(\.fromJIDString) == ["sender@example.com", "sender@example.com"])
        }
    }

    @MainActor
    struct StickyFailure {
        private static func makeFailedService(sid: String) throws -> FileTransferService {
            let service = FileTransferService()
            seedJingleRow(service, sid: sid)
            service.handleJingleEvent(.jingleFileTransferFailed(sid: sid, reason: .checksumMismatch), accountID: testAccountID)
            return service
        }

        @Test
        func `A failed row stays failed after a later progress event`() throws {
            let service = try Self.makeFailedService(sid: "sticky-sid")
            service.handleJingleEvent(.jingleFileTransferProgress(sid: "sticky-sid", bytesTransferred: 500, totalBytes: 1000), accountID: testAccountID)
            #expect(failureReason(service, sid: "sticky-sid") == "The received file is corrupted")
        }

        @Test
        func `A failed row stays failed after a later completion event`() throws {
            let service = try Self.makeFailedService(sid: "sticky-sid")
            service.handleJingleEvent(.jingleFileTransferCompleted(sid: "sticky-sid", transport: .ibb), accountID: testAccountID)
            #expect(failureReason(service, sid: "sticky-sid") == "The received file is corrupted")
        }

        /// A session reports its end once. A row whose session did must not take a later session's outcome just because
        /// the peer reused the sid.
        @Test
        func `A row whose session ended keeps its outcome when the sid is reused`() throws {
            let service = try Self.makeFailedService(sid: "sticky-sid")
            let live = seedJingleRow(service, sid: "sticky-sid")
            service.handleJingleEvent(.jingleFileTransferFailed(sid: "sticky-sid", reason: .decline), accountID: testAccountID)
            #expect(failureReason(service, sid: "sticky-sid") == "The received file is corrupted")
            #expect(failureReason(service, rowID: live) == "The peer declined the transfer")
        }
    }

    struct LinkFileName {
        /// A peer picks the link, and its last component is percent-decoded before it is shown or saved.
        @Test(arguments: [
            ("https://example.com/invoice%E2%80%AEfdp.app", "invoicefdp.app"),
            ("https://example.com/%1B%5B31mred.txt", "[31mred.txt"),
            ("https://example.com/..%2F..%2Fevil.sh", "evil.sh"),
            ("https://example.com/report.pdf", "report.pdf")
        ])
        func `A link's file name is reduced to one visible name`(link: String, expected: String) {
            #expect(Attachment.fileName(forLink: link) == expected)
        }
    }

    @MainActor
    struct OfferOrdering {
        /// Bare `/accept` takes the last offer as the newest, so both kinds have to share one arrival order.
        @Test(arguments: [true, false])
        func `Waiting offers are ordered by arrival across both kinds`(linkFirst: Bool) async throws {
            let service = FileTransferService()
            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let link = XMPPEvent.oobIQOfferReceived(
                OOBIQOffer(offerID: "link-offer", id: "link-id", from: .full(peer), url: "https://example.com/a.bin", desc: nil)
            )
            let file = XMPPEvent.jingleFileTransferReceived(
                JingleFileOffer(offerID: "file-offer", sid: "file-sid", from: peer, fileName: "b.bin", fileSize: 1)
            )

            service.handleJingleEvent(linkFirst ? link : file, accountID: testAccountID)
            try await Task.sleep(for: .milliseconds(5))
            service.handleJingleEvent(linkFirst ? file : link, accountID: testAccountID)

            #expect(service.viewIncomingOffers.map(\.offerID) == (linkFirst ? ["link-offer", "file-offer"] : ["file-offer", "link-offer"]))
        }
    }

    @MainActor
    struct AccountScopedRows {
        @Test
        func `A session's events update only the row of the account they arrived on`() {
            let service = FileTransferService()
            let otherAccountID = UUID()
            seedJingleRow(service, sid: "shared-sid", accountID: otherAccountID)
            seedJingleRow(service, sid: "shared-sid", accountID: testAccountID)

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "shared-sid", reason: .decline), accountID: testAccountID)

            let other = service.activeTransfers.first { $0.accountID == otherAccountID }
            guard case .connectingTransport? = other?.state else {
                Issue.record("Expected the other account's row to stay connecting, got \(String(describing: other?.state))")
                return
            }
            let own = service.activeTransfers.first { $0.accountID == testAccountID }
            guard case .failed("The peer declined the transfer")? = own?.state else {
                Issue.record("Expected the own row to fail, got \(String(describing: own?.state))")
                return
            }
        }

        /// The OOB branch answers before the Jingle lookup is ever reached, so its own account check is the only thing
        /// between an offer and an accept given on another account.
        @Test
        func `Accepting an OOB offer on another account does not find it`() async throws {
            let service = FileTransferService()
            let otherAccountID = UUID()
            try seedOOBOffer(service, id: "shared-oob", offerID: "offer-oob", accountID: otherAccountID)

            // Not found at all: with the account left out of the lookup, the OOB branch would take the other account's
            // offer and fail later, on that account's missing client, instead.
            let error = await #expect(throws: FileTransferService.FileTransferError.self) {
                try await service.acceptIncomingTransfer("offer-oob", accountID: testAccountID)
            }
            #expect(isOfferNotFound(error))

            let other = service.activeTransfers.first { $0.accountID == otherAccountID }
            guard case .awaitingAcceptance? = other?.state else {
                Issue.record("Expected the other account's offer to be untouched, got \(String(describing: other?.state))")
                return
            }
        }

        /// Accepting looks the offer up by offer id *and* account, so one account cannot answer for another's transfer.
        @Test
        func `Accepting an offer on another account does not find it`() async throws {
            let service = FileTransferService()
            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(offerID: "offer-shared", sid: "shared-sid", from: peer, fileName: "file.bin", fileSize: 1)
            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: testAccountID)
            #expect(service.incomingOffers.count == 1)

            let error = await #expect(throws: FileTransferService.FileTransferError.self) {
                try await service.acceptIncomingTransfer("offer-shared", accountID: UUID())
            }
            #expect(isOfferNotFound(error))
            // The offer the other account could not take is still waiting for the one it arrived on.
            #expect(service.incomingOffers.count == 1)
        }
    }

    @MainActor
    struct DisconnectDropsOffers {
        @Test
        func `A disconnect drops only that account's waiting offers and fails only its waiting rows`() throws {
            let service = FileTransferService()
            let otherAccountID = UUID()
            let peer = try #require(FullJID.parse("sender@example.com/res"))
            for (accountID, suffix) in [(testAccountID, "own"), (otherAccountID, "other")] {
                service.handleJingleEvent(
                    .jingleFileTransferReceived(JingleFileOffer(offerID: "file-\(suffix)", sid: "sid-\(suffix)", from: peer, fileName: "f.bin", fileSize: 1)),
                    accountID: accountID
                )
                try seedOOBOffer(service, id: "oob-\(suffix)", offerID: "link-\(suffix)", accountID: accountID)
            }
            let downloading = UUID()
            service.registerTransferForTesting(.init(
                id: downloading, accountID: testAccountID, fileName: "d.bin", fileSize: 0, state: .transferring(progress: 0.5),
                direction: .incoming, sid: "oob-downloading"
            ))

            service.handleJingleEvent(.disconnected(.requested), accountID: testAccountID)

            #expect(service.viewIncomingOffers.map(\.offerID).sorted() == ["file-other", "link-other"])
            #expect(failureReason(service, sid: "oob-own") == JingleTransferFailureReason.disconnected.displayText)
            guard case .awaitingAcceptance? = service.activeTransfers.first(where: { $0.sid == "oob-other" })?.state else {
                Issue.record("Expected the other account's link row to keep waiting")
                return
            }
            guard case .transferring? = service.activeTransfers.first(where: { $0.id == downloading })?.state else {
                Issue.record("Expected the download under way to be left alone")
                return
            }
        }
    }

    @MainActor
    struct JingleEventRouting {
        /// A peer can reuse a sid once its session ended, so a finished row under that sid belongs to the earlier session
        /// and an event for the live one must not rewrite it.
        @Test
        func `An event updates the live row, not a finished one under the same sid`() {
            let service = FileTransferService()
            let finished = seedJingleRow(service, sid: "reused-sid")
            service.handleJingleEvent(.jingleFileTransferCompleted(sid: "reused-sid", transport: .ibb), accountID: testAccountID)
            let live = seedJingleRow(service, sid: "reused-sid")

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "reused-sid", reason: .decline), accountID: testAccountID)

            guard case .completedTransfer? = service.activeTransfers.first(where: { $0.id == finished })?.state else {
                Issue.record("Expected the earlier session's row to stay completed")
                return
            }
            guard case .failed("The peer declined the transfer")? = service.activeTransfers.first(where: { $0.id == live })?.state else {
                Issue.record("Expected the live row to fail")
                return
            }
        }

        /// A link offer's row carries the peer's stanza id, which a Jingle sid can equal. A Jingle event is not about it.
        @Test
        func `A Jingle event under a link offer's id leaves that offer's row alone`() throws {
            let service = FileTransferService()
            try seedOOBOffer(service, id: "oob-1", offerID: "offer-oob-1")
            let control = seedJingleRow(service, sid: "oob-1")

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "oob-1", reason: .cancel), accountID: testAccountID)

            // The event did land on a row, so the link row staying put is not an event that went nowhere.
            #expect(failureReason(service, rowID: control) == "The transfer was canceled")
            guard case .awaitingAcceptance? = service.activeTransfers.first(where: { $0.method == .httpUpload })?.state else {
                Issue.record("Expected the link offer's row to keep waiting")
                return
            }
        }
    }

    struct DownloadFraming {
        private static func downloadFailure(_ response: LoopbackHTTPServer.Response) async throws -> String? {
            let server = try #require(LoopbackHTTPServer(responses: [response]))
            defer { server.stop() }
            return try await withTemporaryDirectory { directory async throws -> String? in
                do {
                    _ = try await FileTransferService.downloadRemoteFile(from: server.url(), named: "file.bin", into: directory)
                    return nil
                } catch {
                    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
                    return error.localizedDescription
                }
            }
        }

        /// A body whose end is only the connection closing, or a chunked body cut off at a chunk boundary, ends like a
        /// whole one, so without a declared length nothing tells a truncated file from a complete one.
        @Test(arguments: [
            LoopbackHTTPServer.Response.Framing.chunked(terminated: false),
            .chunked(terminated: true),
            .closeDelimited
        ])
        func `A body with no declared length is not kept`(framing: LoopbackHTTPServer.Response.Framing) async throws {
            let failure = try await Self.downloadFailure(.init(status: 200, body: [1, 2, 3], framing: framing))
            #expect(failure == "Could not download the file: The server did not provide a file size")
        }

        @Test
        func `A body shorter than its declared length is not kept`() async throws {
            let failure = try await Self.downloadFailure(.init(status: 200, body: [1, 2, 3], framing: .declaredLength(10)))
            #expect(failure != nil)
        }

        /// A declared length counts the encoded bytes, so an encoded body cannot be checked against it once decoded.
        @Test
        func `A body in an encoding is not kept`() async throws {
            let failure = try await Self.downloadFailure(.init(status: 200, body: [1, 2, 3], extraHeaders: ["Content-Encoding: x-test"]))
            #expect(failure == "Could not download the file: The server sent the file in a form whose size cannot be checked")
        }

        /// A server that ignores the request for an unencoded body and compresses it anyway: URLSession decodes such a body
        /// on arrival, so its declared length no longer counts the bytes that arrive.
        @Test
        func `A gzip-encoded body is not kept`() async throws {
            // "ducko " repeated 400 times, gzip-compressed.
            let gzipBody: [UInt8] = [
                0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x4B, 0x29, 0x4D, 0xCE, 0xCE, 0x57, 0x48, 0x19, 0x25, 0x47,
                0xC9, 0x51, 0x72, 0x94, 0x1C, 0x25, 0x47, 0xC9, 0x51, 0x72, 0x94, 0x1C, 0x25, 0xA9, 0x44, 0x02, 0x00, 0x88, 0xBE, 0x2A,
                0x21, 0x60, 0x09, 0x00, 0x00
            ]
            let failure = try await Self.downloadFailure(.init(status: 200, body: gzipBody, extraHeaders: ["Content-Encoding: gzip"]))
            #expect(failure == "Could not download the file: The server sent the file in a form whose size cannot be checked")
        }

        /// A body longer than one write chunk crosses the chunk boundary, where each full chunk is written and counted, and
        /// ends in a partial chunk.
        @Test
        func `A body spanning several write chunks is kept whole`() async throws {
            let body = (0 ..< (2 * 64 * 1024 + 7)).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) }
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: body)]))
            defer { server.stop() }
            try await withTemporaryDirectory { directory in
                let download = try await FileTransferService.downloadRemoteFile(from: server.url(), named: "large.bin", into: directory)

                #expect(download.byteCount == Int64(body.count))
                #expect(try Data(contentsOf: download.fileURL) == Data(body))
            }
        }

        @Test
        func `A body of its declared length is kept, asked for without an encoding`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [1, 2, 3])]))
            defer { server.stop() }
            try await withTemporaryDirectory { directory in
                let download = try await FileTransferService.downloadRemoteFile(from: server.url(), named: "file.bin", into: directory)

                #expect(download.byteCount == 3)
                #expect(try Data(contentsOf: download.fileURL) == Data([1, 2, 3]))
                #expect(server.requests.first?.lowercased().contains("accept-encoding: identity") == true)
            }
        }
    }

    struct ReceivedFiles {
        @Test
        func `A saved file takes the next free name and is quarantined`() async throws {
            try await withTemporaryDirectory { directory in
                let folder = directory.appending(path: "Downloads")
                let first = try await FileTransferService.saveReceivedFile([1, 2, 3], named: "notes.txt", in: folder)
                let second = try await FileTransferService.saveReceivedFile([4], named: "notes.txt", in: folder)

                #expect(first.lastPathComponent == "notes.txt")
                #expect(second.lastPathComponent == "notes 2.txt")
                #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
                #expect(try Data(contentsOf: second) == Data([4]))
                #expect(try second.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
            }
        }

        @Test
        func `A name with no extension is numbered without a trailing dot`() async throws {
            try await withTemporaryDirectory { directory in
                let first = try await FileTransferService.saveReceivedFile([1], named: "README", in: directory)
                let second = try await FileTransferService.saveReceivedFile([2], named: "README", in: directory)

                #expect(first.lastPathComponent == "README")
                #expect(second.lastPathComponent == "README 2")
            }
        }

        /// The name reaches this writer from a peer, and `appending(path:)` honours separators, so containment rests on
        /// the reduction rather than on the caller.
        @Test(arguments: [
            ("../escaped.txt", "escaped.txt"),
            ("../../deeper.txt", "deeper.txt"),
            ("sub/dir/inner.txt", "inner.txt"),
            ("..", "unnamed"),
            (".hidden", "hidden"),
            ("", "unnamed")
        ])
        func `A peer's name cannot place the file outside its directory`(name: String, expected: String) async throws {
            try await withTemporaryDirectory { directory in
                let saved = try await FileTransferService.saveReceivedFile([1], named: name, in: directory)

                #expect(saved.lastPathComponent == expected)
                #expect(saved.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
            }
        }
    }

    @MainActor
    struct JingleProgressTracking {
        @Test
        func `Progress for an offer nobody accepted moves no row and invents none`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(offerID: "progress-offer", sid: "progress-sid", from: peer, fileName: "file.bin", fileSize: 1000)

            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: testAccountID)
            // Armed before the progress event: without this the empty-rows assertion below also holds when offer
            // tracking stopped working altogether.
            #expect(service.incomingOffers.count == 1)

            service.handleJingleEvent(.jingleFileTransferProgress(sid: "progress-sid", bytesTransferred: 500, totalBytes: 1000), accountID: testAccountID)

            // Progress for an offer nobody accepted has no row to move, and must not invent one.
            #expect(service.activeTransfers.isEmpty)
        }
    }

    struct ErrorDescriptions {
        @Test(arguments: [
            (FileTransferService.FileTransferError.fileReadFailed("No such file"), "Could not read the file: No such file"),
            (FileTransferService.FileTransferError.fileSaveFailed("Disk full"), "Could not save the file: Disk full"),
            (FileTransferService.FileTransferError.offerNotFound, "The file offer is no longer waiting"),
            (FileTransferService.FileTransferError.noClient, "Not connected to the server"),
            (FileTransferService.FileTransferError.noUploadModule, "File upload is not available"),
            (FileTransferService.FileTransferError.noJingleModule, "Direct file transfer is not available"),
            (FileTransferService.FileTransferError.uploadFailed("request too large"), "Upload failed: request too large"),
            (FileTransferService.FileTransferError.directTransferUnavailable, "The contact has no device online that can receive files directly")
        ])
        func `FileTransferError renders a readable message`(error: FileTransferService.FileTransferError, expected: String) {
            let error: any Error = error
            #expect(error.localizedDescription == expected)
        }

        @Test(arguments: [(404, "Not found"), (413, "Request too large")])
        func `A failed upload's status reads as a capitalized phrase`(statusCode: Int, expected: String) {
            #expect(FileTransferService.uploadStatusText(statusCode) == expected)
        }
    }

    @MainActor
    struct JingleTerminateRace {
        private static func makeService() -> (FileTransferService, UUID) {
            let service = FileTransferService()
            return (service, seedJingleRow(service, sid: "race-sid"))
        }

        @Test
        func `Session cancellation after the terminate event keeps the terminate reason`() {
            let (service, rowID) = Self.makeService()

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .decline), accountID: testAccountID)
            service.recordJingleTransferFailure(JingleModule.JingleError.sessionNotFound, id: rowID)

            #expect(failureReason(service, rowID: rowID) == "The peer declined the transfer")
        }

        @Test
        func `Terminate event after session cancellation overwrites with the terminate reason`() {
            let (service, rowID) = Self.makeService()

            service.recordJingleTransferFailure(JingleModule.JingleError.sessionNotFound, id: rowID)
            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .decline), accountID: testAccountID)

            #expect(failureReason(service, rowID: rowID) == "The peer declined the transfer")
        }

        @Test
        func `Transport teardown after the terminate event keeps the terminate reason`() {
            let (service, rowID) = Self.makeService()

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .cancel), accountID: testAccountID)
            service.recordJingleTransferFailure(JingleModule.JingleError.transportFailed("The connection was closed"), id: rowID)

            #expect(failureReason(service, rowID: rowID) == "The transfer was canceled")
        }

        @Test
        func `A non-Jingle error after the terminate event is still recorded`() {
            let (service, rowID) = Self.makeService()
            let error = CocoaError(.fileReadNoSuchFile)

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .cancel), accountID: testAccountID)
            service.recordJingleTransferFailure(error, id: rowID)

            #expect(failureReason(service, rowID: rowID) == error.localizedDescription)
        }

        @Test
        func `Session cancellation without a failure event records the error`() {
            let (service, rowID) = Self.makeService()

            service.recordJingleTransferFailure(JingleModule.JingleError.sessionNotFound, id: rowID)

            #expect(failureReason(service, rowID: rowID) == "The file transfer session was not found")
        }
    }

    @MainActor
    struct JingleCompletionTracking {
        @Test
        func `An offer the peer completes before it is accepted leaves nothing behind`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(offerID: "complete-offer", sid: "complete-sid", from: peer, fileName: "file.bin", fileSize: 1000)

            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: testAccountID)
            #expect(service.incomingOffers.count == 1)

            service.handleJingleEvent(.jingleFileTransferCompleted(sid: "complete-sid", transport: .socks5), accountID: testAccountID)

            #expect(service.incomingOffers.isEmpty)
            #expect(service.activeTransfers.isEmpty)
        }
    }

    @MainActor
    struct JingleTaskFailureRecording {
        private static let peerJID = "bob@example.com/res"

        private struct Harness {
            let accountService: AccountService
            let store: MockPersistenceStore
            let chatService: ChatService
            let service: FileTransferService
            let transport: MockTransport
            let accountID: UUID
            let connectTask: Task<Void, any Error>
        }

        private static func connect(downloadsDirectory: URL = FileManager.default.temporaryDirectory) async throws -> Harness {
            let store = MockPersistenceStore()
            let account = try Account(
                id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date()
            )
            await store.addAccount(account)
            let transport = MockTransport()
            let accountService = makeAccountService(
                store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [JingleModule(), OOBModule()])
            )
            try await accountService.loadAccounts()
            let chatService = ChatService(store: store, transcripts: MockTranscriptStore(), filterPipeline: MessageFilterPipeline())
            let service = FileTransferService(downloadsDirectory: downloadsDirectory)
            service.setAccountService(accountService)
            service.setChatService(chatService)
            // Only offers are forwarded: each test replays the failure event itself, so it controls whether the event
            // lands before or after the transfer task's catch runs.
            accountService.onEvent = { [weak service] event, accountID in
                if case .jingleFileTransferReceived = event { service?.handleJingleEvent(event, accountID: accountID) }
                if case .oobIQOfferReceived = event { service?.handleJingleEvent(event, accountID: accountID) }
            }
            // A requested disconnect reaches no event handler, so the purge stands in for `AppEnvironment`'s wiring.
            accountService.onRequestedDisconnect = { [weak service] accountID in service?.purgeAccount(accountID) }
            let (_, connectTask) = try await driveMockConnect(accountService, accountID: account.id, transport: transport)
            return Harness(
                accountService: accountService, store: store, chatService: chatService, service: service,
                transport: transport, accountID: account.id, connectTask: connectTask
            )
        }

        private static func tearDown(_ harness: Harness) async {
            harness.connectTask.cancel()
            await harness.accountService.disconnectAll()
        }

        private static func sessionInitiateXML(sid: String, size: Int = 3) -> String {
            """
            <iq type='set' id='initiate-\(sid)' from='\(peerJID)'>\
            <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='\(peerJID)'>\
            <content creator='initiator' name='a-file-offer'>\
            <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file><name>test.txt</name><size>\(size)</size></file></description>\
            <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'/>\
            </content>\
            </jingle>\
            </iq>
            """
        }

        private static func transportReplaceXML(sid: String, ibbSID: String? = nil) -> String {
            """
            <iq type='set' id='replace-\(sid)' from='\(peerJID)'>\
            <jingle xmlns='urn:xmpp:jingle:1' action='transport-replace' sid='\(sid)'>\
            <content creator='initiator' name='a-file-offer'>\
            <transport xmlns='urn:xmpp:jingle:transports:ibb:1' sid='\(ibbSID ?? "ibb-\(sid)")' block-size='4096'/>\
            </content>\
            </jingle>\
            </iq>
            """
        }

        private static func candidateErrorXML(sid: String) -> String {
            """
            <iq type='set' id='candidate-error-\(sid)' from='\(peerJID)'>\
            <jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
            <content creator='initiator' name='a-file-offer'>\
            <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'><candidate-error/></transport>\
            </content>\
            </jingle>\
            </iq>
            """
        }

        private static func transportAcceptXML(sid: String) -> String {
            """
            <iq type='set' id='accept-\(sid)' from='\(peerJID)'>\
            <jingle xmlns='urn:xmpp:jingle:1' action='transport-accept' sid='\(sid)'>\
            <content creator='initiator' name='a-file-offer'>\
            <transport xmlns='urn:xmpp:jingle:transports:ibb:1' sid='ibb-\(sid)' block-size='4096'/>\
            </content>\
            </jingle>\
            </iq>
            """
        }

        private static func declineXML(sid: String) -> String {
            """
            <iq type='set' id='terminate-\(sid)' from='\(peerJID)'>\
            <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='\(sid)'><reason><decline/></reason></jingle>\
            </iq>
            """
        }

        private static func poll(_ condition: () -> Bool) async throws {
            for _ in 0 ..< 100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        /// Waits for the offer the peer sent under `wireID` — a Jingle sid or an OOB stanza id — and returns the id this
        /// side gave it.
        private static func waitForOffer(_ harness: Harness, wireID: String, from sender: String? = nil) async throws -> String {
            func lookUp() -> String? {
                harness.service.incomingOffers.first { $0.offer.sid == wireID }?.offer.offerID
                    ?? harness.service.incomingOOBOffers.first { pending in
                        pending.offer.id == wireID && (sender == nil || pending.offer.from.description == sender)
                    }?.offer.offerID
            }
            try await poll { lookUp() != nil }
            return try #require(lookUp())
        }

        /// Replays the peer's decline event, then delivers the decline stanza that fails the transfer task's wait.
        private static func deliverDecline(_ harness: Harness, sid: String) async {
            harness.service.handleJingleEvent(.jingleFileTransferFailed(sid: sid, reason: .decline), accountID: harness.accountID)
            await harness.transport.simulateReceive(declineXML(sid: sid))
        }

        /// Takes the one transfer task the test started. Taken before the stanza that ends it, which could otherwise let
        /// the task finish and remove itself first.
        private static func takeTransferTask(_ service: FileTransferService) -> [Task<Void, Never>] {
            let tasks = service.takePendingTasks()
            #expect(tasks.count == 1)
            return tasks
        }

        /// Waits for the taken transfer tasks; a task that never finishes fails the test instead of hanging it.
        private static func drain(_ tasks: [Task<Void, Never>]) async throws {
            let outcome = try await boundedOutcome {
                for task in tasks {
                    await task.value
                }
            }
            #expect(outcome != nil)
        }

        @Test
        func `An accepted transfer keeps the decline after its transport wait fails`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "accept-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "accept-sid")

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)
            await Self.deliverDecline(harness, sid: "accept-sid")
            try await Self.drain(tasks)

            #expect(failureReason(harness.service, sid: "accept-sid") == "The peer declined the transfer")
            await Self.tearDown(harness)
        }

        @Test
        func `A failed accepted transfer keeps its first failure`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "recover-sid", size: 0))
            let offerID = try await Self.waitForOffer(harness, wireID: "recover-sid")

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)
            harness.service.handleJingleEvent(.jingleFileTransferFailed(sid: "recover-sid", reason: .connectivityError), accountID: harness.accountID)
            await harness.transport.simulateReceive(Self.transportReplaceXML(sid: "recover-sid"))
            try await Self.drain(tasks)

            #expect(failureReason(harness.service, sid: "recover-sid") == "The peer could not be reached")
            await Self.tearDown(harness)
        }

        @Test
        func `An accepted transfer of an empty file records the invalid size`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "empty-sid", size: 0))
            let offerID = try await Self.waitForOffer(harness, wireID: "empty-sid")

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)
            await harness.transport.simulateReceive(Self.transportReplaceXML(sid: "empty-sid"))
            try await Self.drain(tasks)

            #expect(failureReason(harness.service, sid: "empty-sid") == "The file size is invalid")
            await Self.tearDown(harness)
        }

        /// Accepting a link reports a saved file only once it was fetched. A `file:` URL is refused before any request goes
        /// out, which makes that observable without a network round trip.
        @Test
        func `An OOB offer this side cannot retrieve reports no completion`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(
                "<iq type='set' id='oob-local' from='\(Self.peerJID)'><query xmlns='jabber:iq:oob'><url>file:///etc/passwd</url></query></iq>"
            )
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-local")

            await #expect(throws: (any Error).self) {
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            }

            let row = harness.service.activeTransfers.first { $0.sid == "oob-local" }
            #expect(row != nil)
            if case .received = row?.state { Issue.record("A link that was never fetched reported a saved file") }
            if case .completedTransfer = row?.state { Issue.record("A link that was never fetched reported a completion") }
            await Self.tearDown(harness)
        }

        private static func oobOfferXML(id: String, url: URL) -> String {
            oobOfferXML(id: id, url: url, from: peerJID)
        }

        /// Whether this side answered the peer's OOB request `id` with a result.
        private static func answeredOffer(_ harness: Harness, id: String) async -> Bool {
            await harness.transport.sentBytes.contains { bytes in
                let stanza = String(decoding: bytes, as: UTF8.self)
                return stanza.contains(id) && stanza.contains("result")
            }
        }

        @Test
        func `An accepted OOB offer is downloaded, saved and recorded before it is answered`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [1, 2, 3])]))
            defer { server.stop() }
            try await withTemporaryDirectory { directory in
                let harness = try await Self.connect(downloadsDirectory: directory)
                await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-ok", url: server.url()))
                let offerID = try await Self.waitForOffer(harness, wireID: "oob-ok")

                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)

                let row = harness.service.activeTransfers.first { $0.sid == "oob-ok" }
                guard case let .received(fileURL)? = row?.state else {
                    Issue.record("Expected a received row, got \(String(describing: row?.state))")
                    await Self.tearDown(harness)
                    return
                }
                #expect(try Data(contentsOf: fileURL) == Data([1, 2, 3]))
                #expect(fileURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
                #expect(row?.peerJIDString == "bob@example.com")
                let conversation = try #require(try await harness.store.fetchConversations(for: harness.accountID).first)
                let message = try #require(await harness.chatService.loadMessages(for: conversation.id).first)
                #expect(message.attachments.first?.origin == .locallySaved)
                #expect(!harness.service.viewIncomingOffers.contains { $0.offerID == offerID })
                #expect(await Self.answeredOffer(harness, id: "oob-ok"))
                await Self.tearDown(harness)
            }
        }

        // A download that fails leaves the offer where the user can accept it again, answers nothing, and lets that retry
        // finish: the row returns to waiting rather than to a failure a later success could not replace.
        @Test
        func `A refused OOB download keeps the offer, answers nothing, and a retry succeeds`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 404, body: Array("gone".utf8)), .init(status: 200, body: [7, 8])]))
            defer { server.stop() }
            try await withTemporaryDirectory { directory in
                let harness = try await Self.connect(downloadsDirectory: directory)
                await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-retry", url: server.url()))
                let offerID = try await Self.waitForOffer(harness, wireID: "oob-retry")

                await #expect(throws: FileTransferService.FileTransferError.self) {
                    try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
                }
                #expect(harness.service.viewIncomingOffers.contains { $0.offerID == offerID })
                #expect(await !Self.answeredOffer(harness, id: "oob-retry"))
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
                guard case .awaitingAcceptance? = harness.service.activeTransfers.first(where: { $0.sid == "oob-retry" })?.state else {
                    Issue.record("Expected the row to wait again after the refused download")
                    await Self.tearDown(harness)
                    return
                }

                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
                guard case let .received(fileURL)? = harness.service.activeTransfers.first(where: { $0.sid == "oob-retry" })?.state else {
                    Issue.record("Expected the retried download to be received")
                    await Self.tearDown(harness)
                    return
                }
                #expect(try Data(contentsOf: fileURL) == Data([7, 8]))
                await Self.tearDown(harness)
            }
        }

        /// A 206 answers a range this side never asked for, and its body is only part of the resource.
        @Test
        func `A partial response is not kept as the file`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 206, body: [1, 2])]))
            defer { server.stop() }
            try await withTemporaryDirectory { directory in
                let harness = try await Self.connect(downloadsDirectory: directory)
                await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-partial", url: server.url()))
                let offerID = try await Self.waitForOffer(harness, wireID: "oob-partial")

                await #expect(throws: FileTransferService.FileTransferError.self) {
                    try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
                }
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
                await Self.tearDown(harness)
            }
        }

        /// While a download runs the offer is claimed, so neither a decline nor a second accept can act on it.
        @Test
        func `An OOB offer being downloaded cannot be declined or accepted again`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [4, 5, 6])]))
            defer { server.stop() }
            server.hold()
            try await withTemporaryDirectory { directory in
                let harness = try await Self.connect(downloadsDirectory: directory)
                await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-busy", url: server.url()))
                let offerID = try await Self.waitForOffer(harness, wireID: "oob-busy")

                let service = harness.service
                let accountID = harness.accountID
                let accept = Task { try await service.acceptIncomingTransfer(offerID, accountID: accountID) }
                try await Self.poll { !service.viewIncomingOffers.contains { $0.offerID == offerID } }
                #expect(!service.viewIncomingOffers.contains { $0.offerID == offerID })

                await #expect(throws: (any Error).self) { try await service.declineIncomingTransfer(offerID, accountID: accountID) }
                await #expect(throws: (any Error).self) { try await service.acceptIncomingTransfer(offerID, accountID: accountID) }

                server.release()
                try await accept.value
                guard case .received? = service.activeTransfers.first(where: { $0.sid == "oob-busy" })?.state else {
                    Issue.record("Expected the one download to be received")
                    await Self.tearDown(harness)
                    return
                }
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
                await Self.tearDown(harness)
            }
        }

        /// A session-accept that fails to go out leaves the session acceptable, so the offer returns to the banner.
        @Test
        func `A session-accept that fails to send returns the offer for another try`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "retry-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "retry-sid")

            await harness.transport.simulateSendFailure(XMPPClientError.notConnected)
            await #expect(throws: (any Error).self) {
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            }
            await harness.transport.simulateSendFailure(nil)

            #expect(harness.service.incomingOffers.contains { $0.offer.sid == "retry-sid" })
            #expect(!harness.service.activeTransfers.contains { $0.sid == "retry-sid" })

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            _ = Self.takeTransferTask(harness.service)
            #expect(harness.service.activeTransfers.contains { $0.sid == "retry-sid" })
            await Self.tearDown(harness)
        }

        /// Plays the peer's side of an outgoing offer until its session exists: answers proxy discovery with no items and
        /// acknowledges the session-initiate. Returns that stanza and the sid it named.
        private static func acknowledgeOffer(_ harness: Harness) async throws -> (stanza: String, sid: String) {
            let discoItems = try #require(await harness.transport.waitForSent(matching: { $0.contains("disco#items") }))
            let discoID = try #require(discoItems.firstMatch(of: /id=["']([^"']+)["']/)?.output.1)
            await harness.transport.simulateReceive(
                "<iq type='result' id='\(discoID)' from='example.com'><query xmlns='http://jabber.org/protocol/disco#items'/></iq>"
            )
            let initiate = try #require(await harness.transport.waitForSent { $0.contains("session-initiate") })
            let initiateID = try #require(initiate.firstMatch(of: /\sid=["']([^"']+)["']/)?.output.1)
            await harness.transport.simulateReceive("<iq type='result' id='\(initiateID)' from='\(peerJID)'/>")
            // The row exists before its session does, so wait for the row to be given the session's sid.
            try await poll { harness.service.activeTransfers.contains { $0.method == .jingle && $0.direction == .outgoing && $0.sid != nil } }
            let sid = try #require(harness.service.activeTransfers.first { $0.method == .jingle && $0.direction == .outgoing }?.sid)
            return (initiate, sid)
        }

        /// A send whose write fails ends its session with an incomplete failure, and that event retires its row and frees
        /// its sid. A later transfer the peer offers under that sid gets its own row rather than the failed send's.
        @Test
        func `A failed send's row does not take a later transfer under its sid`() async throws {
            let harness = try await Self.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appendingPathComponent("jingle.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let service = harness.service
                let accountID = harness.accountID
                let sendTask = Task {
                    try await service.sendFile(url: fileURL, in: makeConversation(), accountID: accountID, method: .jingle, peerJID: Self.peerJID)
                }
                let sid = try await Self.acknowledgeOffer(harness).sid

                // The peer's candidate-error switches the send to IBB and its transport-accept makes that ready; opening
                // the IBB stream then fails, which fails the write.
                await harness.transport.failNextSend(matching: "http://jabber.org/protocol/ibb", error: XMPPClientError.sendFailed("The connection was closed"))
                await harness.transport.simulateReceive(Self.candidateErrorXML(sid: sid))
                _ = await harness.transport.waitForSent { $0.contains("transport-replace") }
                await harness.transport.simulateReceive(Self.transportAcceptXML(sid: sid))
                let sent = try await boundedOutcome { _ = try await sendTask.value }
                guard case .failure? = sent else {
                    Issue.record("Expected the send to fail, got \(String(describing: sent))")
                    await Self.tearDown(harness)
                    return
                }
                // Armed: the failed write ended the session, which is what leaves the sid free for the offer below.
                let transport = harness.transport
                let terminated = try await boundedOutcome {
                    _ = await transport.waitForSent { $0.contains("session-terminate") && $0.contains("failed-transport") }
                }
                try #require(terminated != nil)
                // The session's failure event reaches the service after the send task's catch, as dispatch orders it.
                service.handleJingleEvent(.jingleFileTransferFailed(sid: sid, reason: .incomplete), accountID: accountID)
                #expect(failureReason(service, sid: sid) == JingleTransferFailureReason.incomplete.displayText)

                await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: sid))
                let offerID = try await Self.waitForOffer(harness, wireID: sid)
                try await service.acceptIncomingTransfer(offerID, accountID: accountID)
                _ = Self.takeTransferTask(service)
                service.handleJingleEvent(.jingleFileTransferProgress(sid: sid, bytesTransferred: 1, totalBytes: 3), accountID: accountID)

                let incoming = service.activeTransfers.first { $0.sid == sid && $0.direction == .incoming }
                guard case .transferring? = incoming?.state else {
                    Issue.record("Expected the later transfer's row to take its progress, got \(String(describing: incoming?.state))")
                    await Self.tearDown(harness)
                    return
                }
                await Self.tearDown(harness)
            }
        }

        @Test
        func `A sent transfer keeps the decline after its transport wait fails`() async throws {
            let harness = try await Self.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appendingPathComponent("jingle.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let service = harness.service
                let accountID = harness.accountID
                let sendTask = Task {
                    try await service.sendFile(url: fileURL, in: makeConversation(), accountID: accountID, method: .jingle, peerJID: Self.peerJID)
                }

                let initiate = try await Self.acknowledgeOffer(harness)
                #expect(initiate.stanza.contains("algo=\"sha-256\""))
                #expect(initiate.stanza.contains(JingleFileDescription.sha256Hash(of: Array("abc".utf8))))
                let sid = initiate.sid

                await Self.deliverDecline(harness, sid: sid)
                let outcome = try await boundedOutcome { _ = try? await sendTask.value }
                #expect(outcome != nil)

                #expect(failureReason(harness.service, sid: sid) == "The peer declined the transfer")
                // The file's row in the chat keeps the reason once the transfer row is gone.
                let conversationID = try #require(harness.chatService.openConversations.first?.id)
                let row = try #require(await harness.chatService.loadMessages(for: conversationID).first)
                #expect(row.attachments.first?.localFileURL == fileURL)
                #expect(row.errorText == "The peer declined the transfer")
                await Self.tearDown(harness)
            }
        }

        @Test
        func `A sent transfer takes the decline that arrives after its transport wait failed`() async throws {
            let harness = try await Self.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appendingPathComponent("jingle.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let service = harness.service
                let accountID = harness.accountID
                let sendTask = Task {
                    try await service.sendFile(url: fileURL, in: makeConversation(), accountID: accountID, method: .jingle, peerJID: Self.peerJID)
                }
                let sid = try await Self.acknowledgeOffer(harness).sid

                await harness.transport.simulateReceive(Self.declineXML(sid: sid))
                let outcome = try await boundedOutcome { _ = try? await sendTask.value }
                try #require(outcome != nil)
                service.handleJingleEvent(.jingleFileTransferFailed(sid: sid, reason: .decline), accountID: accountID)

                #expect(failureReason(service, sid: sid) == "The peer declined the transfer")
                // The task's own error named the same reason under a label. Both rows keep the reason alone.
                let conversationID = try #require(harness.chatService.openConversations.first?.id)
                let row = try #require(await harness.chatService.loadMessages(for: conversationID).first)
                #expect(row.errorText == "The peer declined the transfer")
                await Self.tearDown(harness)
            }
        }

        @Test
        func `Accepting an offer replaces its banner with a connecting transfer`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "banner-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "banner-sid")

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)

            #expect(harness.service.incomingOffers.isEmpty)
            let row = harness.service.activeTransfers.first { $0.sid == "banner-sid" }
            // The sender's bare JID is what the chat with them finds the row by.
            #expect(row?.peerJIDString == "bob@example.com")
            let state = row?.state
            guard case .connectingTransport? = state else {
                Issue.record("Expected connectingTransport, got \(String(describing: state))")
                await Self.tearDown(harness)
                return
            }
            await Self.tearDown(harness)
        }

        @Test
        func `An accepted transfer's row follows progress and then completion`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "state-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "state-sid")
            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)

            harness.service.handleJingleEvent(
                .jingleFileTransferProgress(sid: "state-sid", bytesTransferred: 500, totalBytes: 1000),
                accountID: harness.accountID
            )
            if case let .transferring(progress)? = harness.service.activeTransfers.first(where: { $0.sid == "state-sid" })?.state {
                #expect(progress == 0.5)
            } else {
                Issue.record("Expected transferring, got \(String(describing: harness.service.activeTransfers.first { $0.sid == "state-sid" }?.state))")
            }

            harness.service.handleJingleEvent(
                .jingleFileTransferCompleted(sid: "state-sid", transport: .ibb), accountID: harness.accountID
            )
            if case .completedTransfer? = harness.service.activeTransfers.first(where: { $0.sid == "state-sid" })?.state {
                // Expected
            } else {
                Issue.record("Expected completedTransfer, got \(String(describing: harness.service.activeTransfers.first { $0.sid == "state-sid" }?.state))")
            }

            await Self.deliverDecline(harness, sid: "state-sid")
            try await Self.drain(tasks)
            await Self.tearDown(harness)
        }

        @Test
        func `An accepted transfer claims its receive`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "claim-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "claim-sid")
            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let client = try #require(harness.accountService.connectedClient(for: harness.accountID))
            let module = try #require(await client.module(ofType: JingleModule.self))

            // A transport-replace is accepted until the receive task claims the transfer, and rejected from then on.
            var isClaimed = false
            for attempt in 0 ..< 50 where !isClaimed {
                await harness.transport.clearSentBytes()
                await harness.transport.simulateReceive(Self.transportReplaceXML(sid: "claim-sid", ibbSID: "ibb-probe-\(attempt)"))
                let reply = await harness.transport.waitForSent { $0.contains("transport-accept") || $0.contains("transport-reject") }
                isClaimed = reply?.contains("transport-reject") == true
            }
            #expect(isClaimed)

            await #expect(throws: JingleModule.JingleError.transportFailed("The transfer is already being received")) {
                _ = try await module.receiveFileData(sid: "claim-sid")
            }
            await Self.tearDown(harness)
        }

        @Test
        func `An accepted transfer saves the file and adds it to the sender's conversation`() async throws {
            try await withTemporaryDirectory { directory in
                let harness = try await Self.connect(downloadsDirectory: directory)
                await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "save-sid"))
                let offerID = try await Self.waitForOffer(harness, wireID: "save-sid")

                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
                await harness.transport.simulateReceive(Self.transportReplaceXML(sid: "save-sid", ibbSID: "ibb-save"))
                await harness.transport.simulateReceive(
                    "<iq type='set' id='data-0' from='\(Self.peerJID)'><data xmlns='http://jabber.org/protocol/ibb' sid='ibb-save' seq='0'>AQID</data></iq>"
                )
                await harness.transport.simulateReceive(
                    "<iq type='set' id='close-0' from='\(Self.peerJID)'><close xmlns='http://jabber.org/protocol/ibb' sid='ibb-save'/></iq>"
                )
                try await Self.poll { Self.savedFileURL(harness.service, sid: "save-sid") != nil }

                let fileURL = try #require(Self.savedFileURL(harness.service, sid: "save-sid"))
                #expect(fileURL.lastPathComponent == "test.txt")
                #expect(try Data(contentsOf: fileURL) == Data([1, 2, 3]))
                let conversation = try #require(try await harness.store.fetchConversations(for: harness.accountID).first)
                #expect(conversation.jid.description == "bob@example.com")
                let message = try #require(await harness.chatService.loadMessages(for: conversation.id).first)
                #expect(!message.isOutgoing)
                #expect(message.attachments.first?.url == fileURL.absoluteString)
                // Recorded as this app's own file, which is what gives it Quick Look and Reveal in Finder.
                #expect(message.attachments.first?.origin == .locallySaved)
                #expect(message.attachments.first?.localFileURL == fileURL)

                // The transport's own completion is dispatched independently of the save, which awaits both a disk write
                // and a transcript append, so it can land after it. Replayed here in that order: the row has to keep the
                // file it saved, or the UI is left with a bare completion and nothing for Quick Look and Reveal to open.
                harness.service.handleJingleEvent(
                    .jingleFileTransferCompleted(sid: "save-sid", transport: .ibb), accountID: harness.accountID
                )
                harness.service.handleJingleEvent(
                    .jingleFileTransferProgress(sid: "save-sid", bytesTransferred: 1, totalBytes: 3), accountID: harness.accountID
                )
                #expect(Self.savedFileURL(harness.service, sid: "save-sid") == fileURL)
                await Self.tearDown(harness)
            }
        }

        private static func oobOfferXML(id: String, url: URL, from sender: String) -> String {
            "<iq type='set' id='\(id)' from='\(sender)'><query xmlns='jabber:iq:oob'><url>\(url.absoluteString)</url></query></iq>"
        }

        private static func sentStanzas(_ harness: Harness) async -> [String] {
            await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        }

        /// A Jingle sid and a link's stanza id are both the peer's to pick, so they can be equal. Accepting the Jingle offer
        /// takes that offer, and the link stays waiting with nothing fetched.
        @Test
        func `Accepting a Jingle offer leaves a link offer under the same id untouched`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [1])]))
            defer { server.stop() }
            try await withTemporaryDirectory { directory in
                let harness = try await Self.connect(downloadsDirectory: directory)
                await harness.transport.simulateReceive(Self.oobOfferXML(id: "same-id", url: server.url()))
                let linkOfferID = try await Self.waitForOffer(harness, wireID: "same-id")
                await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "same-id"))
                try await Self.poll { !harness.service.incomingOffers.isEmpty }
                let fileOfferID = try #require(harness.service.incomingOffers.first?.offer.offerID)

                try await harness.service.acceptIncomingTransfer(fileOfferID, accountID: harness.accountID)
                _ = Self.takeTransferTask(harness.service)

                #expect(server.requests.isEmpty)
                #expect(harness.service.viewIncomingOffers.map(\.offerID) == [linkOfferID])
                guard case .connectingTransport? = harness.service.activeTransfers.first(where: { $0.method == .jingle })?.state else {
                    Issue.record("Expected the Jingle offer's transfer to start")
                    await Self.tearDown(harness)
                    return
                }
                await Self.tearDown(harness)
            }
        }

        /// Two senders' links under one stanza id are two offers: taking one leaves the other waiting, and the answer goes
        /// to the sender whose link was taken.
        @Test
        func `Accepting one of two links under the same stanza id leaves the other waiting`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [9])]))
            defer { server.stop() }
            try await withTemporaryDirectory { directory in
                let harness = try await Self.connect(downloadsDirectory: directory)
                let other = "carol@example.com/res"
                await harness.transport.simulateReceive(Self.oobOfferXML(id: "shared-id", url: server.url()))
                let first = try await Self.waitForOffer(harness, wireID: "shared-id", from: Self.peerJID)
                await harness.transport.simulateReceive(Self.oobOfferXML(id: "shared-id", url: server.url(), from: other))
                let second = try await Self.waitForOffer(harness, wireID: "shared-id", from: other)
                await harness.transport.clearSentBytes()

                try await harness.service.acceptIncomingTransfer(first, accountID: harness.accountID)

                #expect(harness.service.viewIncomingOffers.map(\.offerID) == [second])
                let waitingRows = harness.service.activeTransfers.filter { row in
                    if case .awaitingAcceptance = row.state { return true }
                    return false
                }
                #expect(waitingRows.count == 1)
                let answers = await Self.sentStanzas(harness).filter { $0.contains("type=\"result\"") }
                #expect(answers.count == 1)
                #expect(answers.first?.contains("to=\"\(Self.peerJID)\"") == true)
                await Self.tearDown(harness)
            }
        }

        /// Decline acts on an offer. Once the offer was accepted the transfer is under way, and declining the id it had
        /// must not end that transfer.
        @Test
        func `Declining an accepted offer does not end its transfer`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "taken-sid"))
            let taken = try await Self.waitForOffer(harness, wireID: "taken-sid")
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "waiting-sid"))
            let waiting = try await Self.waitForOffer(harness, wireID: "waiting-sid")
            try await harness.service.acceptIncomingTransfer(taken, accountID: harness.accountID)
            _ = Self.takeTransferTask(harness.service)

            // Control: declining an offer still waiting does end its session.
            await harness.transport.clearSentBytes()
            try await harness.service.declineIncomingTransfer(waiting, accountID: harness.accountID)
            #expect(await Self.sentStanzas(harness).contains { $0.contains("session-terminate") && $0.contains("waiting-sid") })

            await harness.transport.clearSentBytes()
            let error = await #expect(throws: FileTransferService.FileTransferError.self) {
                try await harness.service.declineIncomingTransfer(taken, accountID: harness.accountID)
            }
            #expect(isOfferNotFound(error))
            #expect(await !Self.sentStanzas(harness).contains { $0.contains("session-terminate") })
            guard case .connectingTransport? = harness.service.activeTransfers.first(where: { $0.sid == "taken-sid" })?.state else {
                Issue.record("Expected the accepted transfer to keep connecting")
                await Self.tearDown(harness)
                return
            }
            await Self.tearDown(harness)
        }

        @Test
        func `Declining a link offer answers it and marks its row declined`() async throws {
            let harness = try await Self.connect()
            try await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-decline", url: #require(URL(string: "https://example.com/a.bin"))))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-decline")
            await harness.transport.clearSentBytes()

            try await harness.service.declineIncomingTransfer(offerID, accountID: harness.accountID)

            #expect(harness.service.viewIncomingOffers.isEmpty)
            #expect(failureReason(harness.service, sid: "oob-decline") == "You declined the transfer")
            #expect(await Self.sentStanzas(harness).contains { $0.contains("oob-decline") && $0.contains("not-acceptable") })
            await Self.tearDown(harness)
        }

        /// A rejection that did not go out leaves the offer waiting, and declining again answers it.
        @Test
        func `A link rejection that fails to send keeps the offer for another try`() async throws {
            let harness = try await Self.connect()
            try await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-reject", url: #require(URL(string: "https://example.com/a.bin"))))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-reject")

            await harness.transport.simulateSendFailure(XMPPClientError.notConnected)
            await #expect(throws: (any Error).self) {
                try await harness.service.declineIncomingTransfer(offerID, accountID: harness.accountID)
            }
            await harness.transport.simulateSendFailure(nil)
            #expect(harness.service.viewIncomingOffers.contains { $0.offerID == offerID })
            guard case .awaitingAcceptance? = harness.service.activeTransfers.first(where: { $0.sid == "oob-reject" })?.state else {
                Issue.record("Expected the row to keep waiting")
                await Self.tearDown(harness)
                return
            }

            await harness.transport.clearSentBytes()
            try await harness.service.declineIncomingTransfer(offerID, accountID: harness.accountID)
            #expect(await Self.sentStanzas(harness).contains { $0.contains("oob-reject") && $0.contains("not-acceptable") })
            await Self.tearDown(harness)
        }

        /// The offer died with the connection that carried it, so a disconnect takes it off the banner and fails its row,
        /// and neither an accept nor a decline finds it afterwards.
        @Test
        func `Disconnecting drops a waiting link offer`() async throws {
            let harness = try await Self.connect()
            try await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-offline", url: #require(URL(string: "https://example.com/a.bin"))))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-offline")
            harness.connectTask.cancel()
            await harness.accountService.disconnectAll()

            #expect(!harness.service.viewIncomingOffers.contains { $0.offerID == offerID })
            #expect(failureReason(harness.service, sid: "oob-offline") == Self.disconnectedText)
            let acceptError = await #expect(throws: FileTransferService.FileTransferError.self) {
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            }
            #expect(isOfferNotFound(acceptError))
            let declineError = await #expect(throws: FileTransferService.FileTransferError.self) {
                try await harness.service.declineIncomingTransfer(offerID, accountID: harness.accountID)
            }
            #expect(isOfferNotFound(declineError))
        }

        private static let disconnectedText = JingleTransferFailureReason.disconnected.displayText

        /// Runs `operation` with its send containing `fragment` held on the wire, drops the account's offers while it is
        /// held, then fails that send, and expects `operation` to throw.
        private static func purgeDuringHeldSend(
            _ harness: Harness, matching fragment: String, _ operation: @escaping @MainActor @Sendable () async throws -> Void
        ) async throws {
            let transport = harness.transport
            await transport.blockSends { $0.contains(fragment) }
            let task = Task { try await operation() }
            // Bounded: a send that never reaches the transport would otherwise hang the test instead of failing it.
            let blocked = try await boundedOutcome { await transport.waitForBlockedSend() }
            try #require(blocked != nil)
            harness.service.purgeAccount(harness.accountID)
            await transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))
            await #expect(throws: (any Error).self) { try await task.value }
        }

        /// A session-accept still in flight when the account's offers are dropped: its failure must not put the offer
        /// back, and its row ends failed rather than connecting. A later session reusing the sid gets its own row.
        @Test
        func `A Jingle accept failing after its offers were dropped fails its row instead of restoring the offer`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "dropped-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "dropped-sid")
            let service = harness.service
            let accountID = harness.accountID

            try await Self.purgeDuringHeldSend(harness, matching: "session-accept") {
                try await service.acceptIncomingTransfer(offerID, accountID: accountID)
            }

            #expect(!service.viewIncomingOffers.contains { $0.offerID == offerID })
            let failedRow = try #require(service.activeTransfers.first { $0.sid == "dropped-sid" }?.id)
            #expect(failureReason(service, rowID: failedRow) == Self.disconnectedText)

            // The peer ends the first session and offers again under its sid.
            await harness.transport.simulateReceive(Self.declineXML(sid: "dropped-sid"))
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "dropped-sid"))
            let secondOfferID = try await Self.waitForOffer(harness, wireID: "dropped-sid")
            try await service.acceptIncomingTransfer(secondOfferID, accountID: accountID)
            _ = Self.takeTransferTask(service)
            service.handleJingleEvent(.jingleFileTransferProgress(sid: "dropped-sid", bytesTransferred: 1, totalBytes: 3), accountID: accountID)

            let liveRow = service.activeTransfers.first { $0.sid == "dropped-sid" && $0.id != failedRow }
            guard case .transferring? = liveRow?.state else {
                Issue.record("Expected the later session's row to take its progress, got \(String(describing: liveRow?.state))")
                await Self.tearDown(harness)
                return
            }
            #expect(failureReason(service, rowID: failedRow) == Self.disconnectedText)
            await Self.tearDown(harness)
        }

        @Test
        func `A link decline failing after its offers were dropped keeps the offer out`() async throws {
            let harness = try await Self.connect()
            try await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-dropped", url: #require(URL(string: "https://example.com/a.bin"))))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-dropped")
            let service = harness.service
            let accountID = harness.accountID

            try await Self.purgeDuringHeldSend(harness, matching: "not-acceptable") {
                try await service.declineIncomingTransfer(offerID, accountID: accountID)
            }

            #expect(!service.viewIncomingOffers.contains { $0.offerID == offerID })
            #expect(failureReason(service, sid: "oob-dropped") == Self.disconnectedText)
            await Self.tearDown(harness)
        }

        /// A download is plain HTTP, so its own failure is the reason; the dropped offer only takes away the retry.
        @Test
        func `A link download failing after its offers were dropped fails with the download's error`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 404, body: Array("gone".utf8))]))
            defer { server.stop() }
            server.hold()
            try await withTemporaryDirectory { directory in
                let harness = try await Self.connect(downloadsDirectory: directory)
                await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-download", url: server.url()))
                let offerID = try await Self.waitForOffer(harness, wireID: "oob-download")
                let service = harness.service
                let accountID = harness.accountID

                let accept = Task { try await service.acceptIncomingTransfer(offerID, accountID: accountID) }
                try await Self.poll { !service.viewIncomingOffers.contains { $0.offerID == offerID } }
                service.purgeAccount(accountID)
                server.release()
                await #expect(throws: (any Error).self) { try await accept.value }

                #expect(!service.viewIncomingOffers.contains { $0.offerID == offerID })
                #expect(failureReason(service, sid: "oob-download") == "Could not download the file: The file is not available at that link")
                await Self.tearDown(harness)
            }
        }

        /// The file is saved and recorded before the answer goes out, so an answer that cannot be sent does not undo the
        /// transfer or report it as failed.
        @Test
        func `A link whose acknowledgement fails to send is still received`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [5, 6])]))
            defer { server.stop() }
            try await withTemporaryDirectory { directory in
                let harness = try await Self.connect(downloadsDirectory: directory)
                await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-ack", url: server.url()))
                let offerID = try await Self.waitForOffer(harness, wireID: "oob-ack")

                await harness.transport.clearSentBytes()
                await harness.transport.simulateSendFailure(XMPPClientError.notConnected)
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
                await harness.transport.simulateSendFailure(nil)

                guard case let .received(fileURL)? = harness.service.activeTransfers.first(where: { $0.sid == "oob-ack" })?.state else {
                    Issue.record("Expected the downloaded link to be received")
                    await Self.tearDown(harness)
                    return
                }
                #expect(try Data(contentsOf: fileURL) == Data([5, 6]))
                #expect(await !Self.answeredOffer(harness, id: "oob-ack"))
                await Self.tearDown(harness)
            }
        }

        private static func savedFileURL(_ service: FileTransferService, sid: String) -> URL? {
            guard case let .received(fileURL) = service.activeTransfers.first(where: { $0.sid == sid })?.state else { return nil }
            return fileURL
        }
    }
}
