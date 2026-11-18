import DuckoTestSupport
import Testing
@testable import DuckoXMPP

/// A content offering a 3-byte file over IBB stream `ibb-sid` from the start.
private let ibbFirstContent = JingleContent(
    name: "a-file-offer", creator: "initiator", description: JingleFileDescription(name: "test.txt", size: 3),
    transport: .ibb(IBBTransport(sid: "ibb-sid", blockSize: 4096))
).toXML()

private let incomplete = JingleModule.JingleError.transportFailed("The transfer ended before the whole file arrived")

/// Delivers the peer's unavailable presence, from its full JID or, when `bare`, its bare JID.
private func deliverUnavailable(to harness: JingleInitiatorHarness, bare: Bool = false) {
    var presence = XMPPPresence(type: .unavailable)
    presence.from = bare ? .bare(JingleInitiatorHarness.peer.bareJID) : .full(JingleInitiatorHarness.peer)
    harness.module.handlePresence(presence)
}

private func isGoneFailure(_ event: XMPPEvent) -> Bool {
    if case .jingleFileTransferFailed(_, _, .gone) = event { return true }
    return false
}

private func isIBBData(_ iq: XMLElement) -> Bool {
    iq.child(named: "data", namespace: XMPPNamespaces.ibb) != nil
}

/// What `task` returns, or `nil` when it throws or is still running after a few seconds.
private func boundedValue<Success: Sendable>(of task: Task<Success, any Error>) async throws -> Success? {
    guard case .success? = try await boundedOutcome(timeout: .seconds(5), of: { _ = try await task.value }) else { return nil }
    return try await task.value
}

/// Accepts the peer's offer of `file` and switches it to IBB stream `ibb-sid`, as the peer's transport-replace would.
private func startIBBReceive(_ harness: JingleInitiatorHarness, file: JingleFileDescription) async throws {
    try harness.receiveOffer(sid: "sid-1", file: file)
    try await harness.module.acceptFileTransfer(sid: "sid-1")
    try harness.receive(action: JingleAction.transportReplace.rawValue, sid: "sid-1", payload: [JingleInitiatorHarness.ibbContent()])
}

enum JinglePeerActivityTests {
    struct PresenceGrace {
        private static let grace = JingleTiming(senderConfirmationWait: .milliseconds(300), peerUnavailableGrace: .milliseconds(200))

        @Test(arguments: [true, false], [true, false])
        func `A session not yet carrying data ends once its peer stays unavailable for the grace`(sending: Bool, bare: Bool) async throws {
            let harness = JingleInitiatorHarness(timing: Self.grace)
            let sid: String
            if sending {
                sid = try await harness.initiate()
            } else {
                sid = "sid-1"
                try harness.receiveOffer(sid: sid)
            }

            deliverUnavailable(to: harness, bare: bare)

            let terminate = try #require(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)?.child(named: "jingle"))
            #expect(terminate.attribute("sid") == sid)
            #expect(terminate.child(named: "reason")?.child(named: "gone") != nil)
            #expect(harness.eventCount { if case .jingleFileTransferFailed(sid, _, .gone) = $0 { true } else { false } } == 1)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await harness.module.awaitTransportReady(sid: sid)
            }
        }

        @Test(arguments: ["jingle", "ibb"])
        func `A stanza from the peer cancels the grace`(stanza: String) async throws {
            let harness = JingleInitiatorHarness(timing: Self.grace)
            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-1", payload: [ibbFirstContent])

            deliverUnavailable(to: harness)
            if stanza == "jingle" {
                try harness.receive(action: JingleAction.sessionInfo.rawValue, sid: "sid-1", id: "ping")
            } else {
                try harness.deliver(JingleInitiatorHarness.ibbOpen(), id: "ping")
            }
            #expect(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "ping", type: "result")) != nil)

            try await Task.sleep(for: .milliseconds(500))
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 0)
            try await harness.module.acceptFileTransfer(sid: "sid-1")
        }

        /// A connected SOCKS5 receive waiting on a read that spans the grace relies on its own stall wait.
        @Test
        func `A connected SOCKS5 receive outlasts its peer's unavailable presence`() async throws {
            let harness = JingleInitiatorHarness(timing: Self.grace)
            let peer = try await harness.acceptSOCKS5Offer(listener: harness.receiveSOCKS5Offer())
            let module = harness.module
            let receive = Task { try await module.receiveFileData(sid: "sid-1") }

            deliverUnavailable(to: harness)
            try await Task.sleep(for: .milliseconds(500))
            try await peer.send([1, 2, 3])

            #expect(try await boundedValue(of: receive) == [1, 2, 3])
            #expect(harness.eventCount(matching: isGoneFailure) == 0)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
        }

        /// A grace armed while the offer waited for acceptance finds the session carrying data once it expires.
        @Test
        func `A grace armed before SOCKS5 connected does not end the session past its deadline`() async throws {
            // Long enough for the dial to finish within it.
            let grace = Duration.seconds(1)
            let harness = JingleInitiatorHarness(timing: JingleTiming(peerUnavailableGrace: grace))
            let listener = try await harness.receiveSOCKS5Offer()

            let armedAt = ContinuousClock.now
            deliverUnavailable(to: harness)
            let peer = try await harness.acceptSOCKS5Offer(listener: listener)
            try await Task.sleep(until: armedAt + grace + .milliseconds(300), clock: .continuous)

            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
            try await peer.send([1, 2, 3])
            let module = harness.module
            #expect(try await boundedValue(of: Task { try await module.receiveFileData(sid: "sid-1") }) == [1, 2, 3])
        }

        /// The receiver's acknowledgements are IQ results, which never reach the module, so they cannot count as activity.
        @Test
        func `An IBB send outlasts its peer's unavailable presence while its blocks are acknowledged`() async throws {
            let harness = JingleInitiatorHarness(timing: Self.grace) { iq in
                if isIBBData(iq) { try await Task.sleep(for: .milliseconds(50)) }
                return nil
            }
            let sid = try await harness.initiate()
            try harness.receive(action: JingleAction.transportReplace.rawValue, sid: sid, payload: [JingleInitiatorHarness.ibbContent()])
            let module = harness.module
            let send = Task { try await module.sendFileData(sid: sid, data: [UInt8](repeating: 7, count: 4096 * 10)) }

            #expect(try await harness.sentIQ(matching: isIBBData) != nil)
            deliverUnavailable(to: harness)
            // The receiver confirms only once the last block is in, long after the grace would have ended the session.
            let close = try await harness.sentIQ(timeout: .seconds(5)) { $0.child(named: "close", namespace: XMPPNamespaces.ibb) != nil }
            #expect(close != nil)
            try harness.receive(
                action: JingleAction.sessionInfo.rawValue, sid: sid,
                payload: [XMLElement(name: "received", namespace: XMPPNamespaces.jingleFileTransfer)]
            )

            let outcome = try await boundedOutcome(timeout: .seconds(5)) { try await send.value }
            guard case .success? = outcome else {
                Issue.record("Expected the send to finish, got \(String(describing: outcome))")
                return
            }
            #expect(harness.sentIQCount(matching: isIBBData) == 10)
            #expect(harness.eventCount(matching: isGoneFailure) == 0)
        }
    }

    struct IBBStall {
        /// The bytes that arrived before the claim make no difference: nothing further arrives either way.
        @Test(arguments: [[], [1]] as [[UInt8]])
        func `A claimed IBB receive that gets no further block fails as incomplete`(early: [UInt8]) async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(receiveStallWait: .milliseconds(300)))
            try await startIBBReceive(harness, file: JingleFileDescription(name: "test.txt", size: 3))
            if !early.isEmpty {
                try harness.deliver(JingleInitiatorHarness.ibbData(early, seq: 0), id: "data-0")
            }

            let module = harness.module
            let outcome = try await boundedOutcome(timeout: .seconds(5)) { _ = try await module.receiveFileData(sid: "sid-1") }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the stalled receive to fail, got \(String(describing: outcome))")
                return
            }
            #expect(error as? JingleModule.JingleError == incomplete)
            #expect(harness.eventCount { if case .jingleFileTransferFailed("sid-1", _, .incomplete) = $0 { true } else { false } } == 1)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "cancel") != nil)
        }

        /// Counted from the arming, the wait would end half a wait after the block; re-armed from each wake-up, half a wait
        /// late.
        @Test
        func `A stall counts from the last block`() async throws {
            let wait = Duration.seconds(1)
            let harness = JingleInitiatorHarness(timing: JingleTiming(receiveStallWait: wait))
            try await startIBBReceive(harness, file: JingleFileDescription(name: "test.txt", size: 3))
            let module = harness.module
            let failedAt = Task { () -> ContinuousClock.Instant? in
                do {
                    _ = try await module.receiveFileData(sid: "sid-1")
                    return nil
                } catch {
                    return .now
                }
            }

            try await Task.sleep(for: wait / 2)
            let lastBlockAt = ContinuousClock.now
            try harness.deliver(JingleInitiatorHarness.ibbData([1], seq: 0), id: "data-0")

            _ = try await boundedOutcome(timeout: .seconds(5)) { _ = await failedAt.value }
            let failure = try #require(await failedAt.value)
            #expect(failure - lastBlockAt >= wait)
            #expect(failure - lastBlockAt < wait * 1.4)
        }

        @Test
        func `Blocks arriving within the stall wait keep the receive going past several waits`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(receiveStallWait: .milliseconds(500)))
            let size = 15
            try await startIBBReceive(harness, file: JingleFileDescription(name: "test.txt", size: Int64(size)))
            let module = harness.module
            let receive = Task { try await module.receiveFileData(sid: "sid-1") }

            for seq in 0 ..< size {
                try await Task.sleep(for: .milliseconds(100))
                try harness.deliver(JingleInitiatorHarness.ibbData([UInt8(seq)], seq: UInt16(seq)), id: "data-\(seq)")
            }
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            #expect(try await boundedValue(of: receive) == (0 ..< size).map(UInt8.init))
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }
    }
}
