import DuckoTestSupport
import Testing
@testable import DuckoXMPP

/// The offer id a transfer event names its session by.
private func offerID(of event: XMPPEvent?) -> String? {
    if case let .jingleFileTransferProgress(_, offerID, _, _, _)? = event { return offerID }
    if case let .jingleFileTransferCompleted(_, offerID, _)? = event { return offerID }
    return nil
}

private func isProgress(_ event: XMPPEvent) -> Bool {
    if case .jingleFileTransferProgress = event { return true }
    return false
}

/// A file source whose second read holds until the test releases it.
private actor HeldSecondReadSource: JingleFileSource {
    let readHeld = AsyncSemaphore()
    let release = AsyncSemaphore()
    private let bytes: [UInt8]
    private var offset = 0
    private var reads = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func read(upTo count: Int) async -> [UInt8] {
        reads += 1
        if reads == 2 {
            await readHeld.signal()
            await release.wait()
        }
        let end = min(offset + count, bytes.count)
        defer { offset = end }
        return Array(bytes[offset ..< end])
    }
}

/// A session is named by the id of its offer, which a later session reusing its sid does not share.
enum JingleOfferScopeTests {
    struct EventIdentity {
        @Test
        func `A send's progress and completion carry the offer id it was started with`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.module.initiateFileTransfer(
                to: JingleInitiatorHarness.peer, file: JingleFileDescription(name: "test.txt", size: 3), offerID: "sent-offer"
            )
            try harness.receive(action: "transport-replace", sid: sid, payload: [JingleInitiatorHarness.ibbContent()])
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [1, 2, 3]) }

            let progress = try await harness.event(matching: isProgress)
            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])
            _ = try await boundedOutcome { try await send.value }
            let completion = try await harness.event(matching: JingleInitiatorHarness.isCompletion)

            #expect(offerID(of: progress) == "sent-offer")
            #expect(offerID(of: completion) == "sent-offer")
        }

        @Test
        func `A receive's progress and completion carry the id of its offer`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")
            let offered = try #require(harness.receivedOffers().first?.offerID)
            try await harness.module.acceptFileTransfer(sid: "sid-1")
            try harness.receive(action: "transport-replace", sid: "sid-1", payload: [JingleInitiatorHarness.ibbContent()])
            let receive = Task { try await harness.module.receiveFileData(sid: "sid-1") }

            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")
            _ = try await boundedOutcome { _ = try await receive.value }

            #expect(try await offerID(of: harness.event(matching: isProgress)) == offered)
            #expect(try await offerID(of: harness.event(matching: JingleInitiatorHarness.isCompletion)) == offered)
        }
    }

    struct DeferredWork {
        /// The stop lands while the next block is read, so that block was read for a session that no longer exists.
        @Test
        func `A block read while its session ends is not sent`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()
            try harness.receive(action: "transport-replace", sid: sid, payload: [JingleInitiatorHarness.ibbContent()])
            let blockSize = 4096
            let source = HeldSecondReadSource([UInt8](repeating: 7, count: 2 * blockSize))
            let send = Task { try await harness.module.sendFileData(sid: sid, source: source, totalBytes: Int64(2 * blockSize)) }
            try #require(try await boundedOutcome { await source.readHeld.wait() } != nil)

            try await harness.module.terminateSession(sid: sid, reason: .cancel)
            await source.release.signal()

            let outcome = try await boundedOutcome { try await send.value }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the send to fail, got \(String(describing: outcome))")
                return
            }
            #expect(error as? JingleModule.JingleError == .sessionNotFound)
            #expect(harness.sentIQCount { $0.child(named: "data", namespace: XMPPNamespaces.ibb) != nil } == 1)
        }

        /// The fallback's transport-replace fails only once its session ended and the peer offered a file under the same
        /// sid. Abandoning the transport then concerns the session that proposed the replace, not the later offer.
        @Test
        func `A transport-replace that fails after its session ended leaves a later session under the sid alone`() async throws {
            let (replaceSent, replaceFails) = (AsyncSemaphore(), AsyncSemaphore())
            let harness = JingleInitiatorHarness(sending: { stanza in
                guard stanza.child(named: "jingle")?.attribute("action") == JingleAction.transportReplace.rawValue else { return }
                await replaceSent.signal()
                await replaceFails.wait()
                throw XMPPClientError.sendFailed("The connection was closed")
            })
            let sid = try await harness.initiate()
            try harness.receive(
                action: JingleAction.transportInfo.rawValue, sid: sid,
                payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))]
            )
            try #require(try await boundedOutcome { await replaceSent.wait() } != nil)

            try await harness.module.terminateSession(sid: sid, reason: .cancel)
            try harness.receiveOffer(sid: sid)
            let later = try #require(harness.receivedOffers().last?.offerID)
            await replaceFails.signal()

            // A failure event would follow the failed send at once; none within the wait means the later offer was spared.
            #expect(try await harness.event(timeout: .milliseconds(500), matching: JingleInitiatorHarness.isFailure) == nil)
            try await harness.module.acceptFileTransfer(sid: sid, offerID: later)
        }
    }
}
