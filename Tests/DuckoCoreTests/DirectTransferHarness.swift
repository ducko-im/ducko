import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

/// An account connected through a mock client, whose peer answers every request, takes files in band and offers its
/// own. Only offers reach the service as events: a test replays any other event itself, so it decides when the event
/// lands. The module's failure events are kept in `failureEvents` for that. A requested disconnect purges the account,
/// as `AppEnvironment` wires it.
@MainActor
struct DirectTransferHarness {
    static let peerJID = "bob@example.com/res"

    /// The module's failure events, in order, which the service has not been given.
    @MainActor
    final class EventLog {
        fileprivate(set) var events: [XMPPEvent] = []
    }

    let service: FileTransferService
    let chatService: ChatService
    let store: MockPersistenceStore
    let transcripts: MockTranscriptStore
    let transport: MockTransport
    let accountService: AccountService
    let accountID: UUID
    let conversation: Conversation
    let connectTask: Task<Void, any Error>
    let failureEvents: EventLog

    /// - Parameters:
    ///   - takesLinkOffers: Whether the account also takes the peer's links (XEP-0066), whose offers reach the service
    ///     like a file's.
    ///   - senderConfirmationWait: How long a finished send waits for the peer to confirm the file.
    static func connect(
        downloadsDirectory: URL = FileManager.default.temporaryDirectory, takesLinkOffers: Bool = false,
        senderConfirmationWait: Duration = .milliseconds(100)
    ) async throws -> DirectTransferHarness {
        let store = MockPersistenceStore()
        let account = try Account(
            id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date()
        )
        await store.addAccount(account)
        let transport = MockTransport()
        await answerRequests(on: transport)
        let jingleModule = JingleModule(
            timing: JingleTiming(senderConfirmationWait: senderConfirmationWait, peerEndGrace: .milliseconds(100))
        )
        let modules: [any XMPPModule] = takesLinkOffers ? [jingleModule, OOBModule()] : [jingleModule]
        let accountService = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: modules))
        try await accountService.loadAccounts()
        let service = FileTransferService(downloadsDirectory: downloadsDirectory)
        service.setAccountService(accountService)
        let transcripts = MockTranscriptStore()
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        service.setChatService(chatService)
        let failureEvents = EventLog()
        accountService.onEvent = { [weak service] event, accountID in
            if case .jingleFileTransferReceived = event { service?.handleJingleEvent(event, accountID: accountID) }
            if case .oobIQOfferReceived = event { service?.handleJingleEvent(event, accountID: accountID) }
            if case .jingleFileTransferFailed = event { failureEvents.events.append(event) }
        }
        accountService.onRequestedDisconnect = { [weak service] accountID in service?.purgeAccount(accountID) }
        let (_, connectTask) = try await driveMockConnect(accountService, accountID: account.id, transport: transport)
        let conversation = try Conversation(
            id: UUID(), accountID: account.id, jid: #require(BareJID.parse("bob@example.com")), type: .chat,
            isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
        )
        return DirectTransferHarness(
            service: service, chatService: chatService, store: store, transcripts: transcripts, transport: transport,
            accountService: accountService, accountID: account.id, conversation: conversation, connectTask: connectTask,
            failureEvents: failureEvents
        )
    }

    /// Answers the server's disco#items and every request to the peer with an empty result.
    private static func answerRequests(on transport: MockTransport) async {
        let peerJID = peerJID
        await transport.autoReply { stanza in
            guard let id = stanza.firstMatch(of: /\sid=["']([^"']+)["']/)?.output.1,
                  let to = stanza.firstMatch(of: /\sto=["']([^"']+)["']/)?.output.1 else { return nil }
            if stanza.contains("disco#items") {
                return "<iq type='result' id='\(id)' from='\(to)'><query xmlns='http://jabber.org/protocol/disco#items'/></iq>"
            }
            guard to == peerJID, stanza.contains("type=\"set\"") else { return nil }
            return "<iq type='result' id='\(id)' from='\(to)'/>"
        }
    }

    // MARK: - Sending

    /// Sends `fileURL` directly to the peer and returns the sid of the offer once it went out.
    func send(_ fileURL: URL) async throws -> (task: Task<Void, any Error>, sid: String) {
        let task = startSending(fileURL)
        let initiate = try await sentStanza(on: transport, containing: "session-initiate")
        let sid = try String(#require(initiate.firstMatch(of: /\ssid=["']([^"']+)["']/)?.output.1))
        return (task, sid)
    }

    /// Sends `fileURL` directly to the peer.
    func startSending(_ fileURL: URL) -> Task<Void, any Error> {
        let (service, conversation, accountID) = (service, conversation, accountID)
        return Task {
            _ = try await service.sendFile(url: fileURL, in: conversation, accountID: accountID, method: .jingle, peerJID: Self.peerJID)
        }
    }

    /// Waits until the send took the sid of its answered offer, so it is waiting for its connection.
    func awaitAnsweredOffer(sid: String) async throws {
        let service = service
        let adopted = try await boundedOutcome {
            while await service.activeTransfers.first?.sid != sid {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try #require(adopted != nil)
    }

    /// Plays the peer's part in the fallback to in-band: it reports that no candidate worked and accepts the
    /// transport-replace this side proposes, which makes the connection ready.
    func switchToIBB(sid: String) async throws {
        await transport.simulateReceive(Self.candidateErrorXML(sid: sid))
        _ = try await sentStanza(on: transport, containing: "transport-replace")
        await transport.simulateReceive(Self.transportAcceptXML(sid: sid))
    }

    /// The outcomes stored for directly sent files, in the order they were stored: each failure's text, or `nil` for a
    /// file stored as delivered.
    func storedOutcomes() async -> [String?] {
        await transcripts.amendments.map(\.amendment).filter { $0.action == .error || $0.action == .delivery }.map(\.errorText)
    }

    func sentIBBOpen() async -> Bool {
        await transport.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("<open") }
    }

    // MARK: - Receiving

    /// Plays the peer offering `test.txt` of `size` bytes under `sid`, and returns the id this side gave the offer once
    /// it waits on the user.
    func receiveOffer(sid: String, size: Int = 3) async throws -> String {
        await transport.simulateReceive(Self.sessionInitiateXML(sid: sid, size: size))
        for _ in 0 ..< 100 {
            if let offerID = service.incomingOffers.first(where: { $0.offer.sid == sid })?.offer.offerID { return offerID }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The offer under \(sid) never reached the service")
        throw CancellationError()
    }

    /// The module's failure events for the session under `sid` so far.
    func failureEvents(sid: String) -> [XMPPEvent] {
        failureEvents.events.filter { event in
            if case .jingleFileTransferFailed(sid, _, _) = event { true } else { false }
        }
    }

    /// Waits for the module's failure event for the session under `sid`, which the service has not been given.
    func failureEvent(sid: String) async throws -> XMPPEvent {
        for _ in 0 ..< 100 {
            if let event = failureEvents.events.first(where: { event in
                if case .jingleFileTransferFailed(sid, _, _) = event { true } else { false }
            }) {
                return event
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The session under \(sid) never reported a failure")
        throw CancellationError()
    }

    /// The id this side gave the offer of the file it is sending.
    func outgoingOfferID() throws -> String {
        try #require(service.activeTransfers.first { $0.direction == .outgoing }?.offerID)
    }

    /// The id of the incoming row of the session under `sid` that has not failed.
    func incomingRowID(sid: String) throws -> UUID {
        try #require(service.activeTransfers.first { row in
            guard row.direction == .incoming, row.sid == sid else { return false }
            if case .failed = row.state { return false }
            return true
        }?.id)
    }

    /// Plays the peer switching its offer under `sid` to in-band, as the stream `ibbSID`.
    func peerSwitchesToIBB(sid: String, ibbSID: String) async {
        await transport.simulateReceive("""
        <iq type='set' id='replace-\(sid)' from='\(Self.peerJID)'>\
        <jingle xmlns='urn:xmpp:jingle:1' action='transport-replace' sid='\(sid)'>\
        <content creator='initiator' name='a-file-offer'>\
        <transport xmlns='urn:xmpp:jingle:transports:ibb:1' sid='\(ibbSID)' block-size='4096'/>\
        </content>\
        </jingle>\
        </iq>
        """)
    }

    /// Plays the peer ending the session under `sid` for `reason`.
    func peerTerminates(sid: String, reason: String) async {
        await transport.simulateReceive("""
        <iq type='set' id='terminate-\(sid)' from='\(Self.peerJID)'>\
        <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='\(sid)'><reason><\(reason)/></reason></jingle>\
        </iq>
        """)
    }

    // MARK: - Teardown

    /// Waits for every task the service started, including those the awaited tasks start in turn. A task that never
    /// finishes fails the test.
    func drainTasks() async throws {
        let service = service
        let outcome = try await boundedOutcome {
            while case let tasks = await service.takePendingTasks(), !tasks.isEmpty {
                for task in tasks {
                    await task.value
                }
            }
        }
        #expect(outcome != nil)
    }

    func tearDown() async {
        // The service holds its chat service weakly, so the harness keeps it alive until here.
        withExtendedLifetime(chatService) {}
        connectTask.cancel()
        await accountService.disconnectAll()
    }

    static func sessionInitiateXML(sid: String, size: Int = 3) -> String {
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
}
