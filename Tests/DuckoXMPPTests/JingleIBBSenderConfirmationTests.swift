import DuckoTestSupport
import Testing
@testable import DuckoXMPP

extension JingleIBBFallbackTests {
    struct SenderConfirmation {
        @Test
        func `A received confirmation arriving before the close's result still returns`() async throws {
            let gated = GatedCloseHarness()
            let harness = gated.harness
            let sid = try await startIBBSend(harness)
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [1, 2, 3]) }

            await gated.closeSent.wait()
            try harness.receive(action: "session-info", sid: sid, payload: [received])
            await gated.closeAnswered.signal()

            let outcome = try await boundedOutcome { try await send.value }
            guard case .success? = outcome else {
                Issue.record("Expected the send to return, got \(String(describing: outcome))")
                return
            }
        }

        /// A harness whose IBB close is sent, then waits until the test answers it.
        private struct GatedCloseHarness {
            let harness: JingleInitiatorHarness
            let closeSent = AsyncSemaphore()
            let closeAnswered = AsyncSemaphore()

            init(timing: JingleTiming = JingleTiming()) {
                let closeSent = closeSent
                let closeAnswered = closeAnswered
                self.harness = JingleInitiatorHarness(timing: timing) { iq in
                    if iq.child(named: "close", namespace: XMPPNamespaces.ibb) != nil {
                        await closeSent.signal()
                        await closeAnswered.wait()
                    }
                    return nil
                }
            }
        }

        /// The confirmed branch of the sender's cleanup: the receiver acknowledges with `<received/>` and then never
        /// sends the terminate — a peer that crashes or drops between the two. Left uncovered, the session, its
        /// transport and its send record leak for the life of the connection, or the timer fires at a sid a later
        /// session has since taken.
        @Test
        func `A confirmed send terminates itself when the peer never does`() async throws {
            let gated = GatedCloseHarness(timing: .short)
            let harness = gated.harness
            let sid = try await startIBBSend(harness)
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [1, 2, 3]) }

            await gated.closeSent.wait()
            try harness.receive(action: "session-info", sid: sid, payload: [received])
            await gated.closeAnswered.signal()
            _ = try await boundedOutcome { try await send.value }

            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "success") != nil)
        }

        @Test
        func `The receiver's terminate after its received confirmation completes the session once`() async throws {
            let gated = GatedCloseHarness()
            let harness = gated.harness
            let sid = try await startIBBSend(harness)
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [1, 2, 3]) }
            await gated.closeSent.wait()
            try harness.receive(action: "session-info", sid: sid, payload: [received])
            await gated.closeAnswered.signal()
            try await send.value

            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])
            #expect(try await harness.event(matching: JingleInitiatorHarness.isCompletion) != nil)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }

        /// Only the receiver can say the file arrived, so a send it never confirms fails rather than counting as sent.
        @Test
        func `Without a confirmation the send fails as unconfirmed and terminates with timeout after the wait`() async throws {
            let harness = JingleInitiatorHarness(timing: .short)
            let sid = try await startIBBSend(harness)

            await #expect(throws: JingleModule.JingleError.transportFailed(JingleTransferFailureReason.unconfirmed.displayText)) {
                try await harness.module.sendFileData(sid: sid, data: [1, 2, 3])
            }
            let terminate = try #require(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue))
            #expect(terminate.child(named: "jingle")?.child(named: "reason")?.child(named: "timeout") != nil)
            #expect(harness.eventCount { if case .jingleFileTransferFailed(sid, _, .unconfirmed) = $0 { true } else { false } } == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 0)
        }

        /// The receiver's cancel lands while the send waits for its confirmation. Its end removes the session, so the send
        /// fails with the receiver's reason once, and no timeout follows.
        @Test
        func `A cancel while the send waits for its confirmation fails the send once with the receiver's reason`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(senderConfirmationWait: .seconds(10)))
            let sid = try await startIBBSend(harness)
            let module = harness.module
            let send = Task { try await module.sendFileData(sid: sid, data: [1, 2, 3]) }
            // Armed: every block is written and the send waits for the receiver.
            try await eventually { module.state.withLock { $0.resources[sid]?.send?.wait != nil } }

            try harness.receive(action: JingleAction.sessionTerminate.rawValue, sid: sid, payload: [JingleInitiatorHarness.reason("cancel")])

            await #expect(throws: JingleModule.JingleError.transportFailed(JingleTransferFailureReason.cancel.displayText)) {
                try await send.value
            }
            #expect(harness.eventCount { if case .jingleFileTransferFailed(sid, _, .cancel) = $0 { true } else { false } } == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 1)
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 0)
        }

        /// The session went with the decision that the send failed, so a terminate that cannot be sent changes nothing.
        @Test
        func `An unconfirmed send whose terminate fails to send still fails once as unconfirmed`() async throws {
            let harness = JingleInitiatorHarness(timing: .short, failingActions: [JingleAction.sessionTerminate.rawValue])
            let sid = try await startIBBSend(harness)

            await #expect(throws: JingleModule.JingleError.transportFailed(JingleTransferFailureReason.unconfirmed.displayText)) {
                try await harness.module.sendFileData(sid: sid, data: [1, 2, 3])
            }
            // Armed: the terminate was attempted, and its send failed.
            _ = try #require(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue))
            #expect(harness.eventCount { if case .jingleFileTransferFailed(sid, _, .unconfirmed) = $0 { true } else { false } } == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 0)
        }

        /// The receiver already holds every acknowledged block. A close it refuses, because it finished the stream on its
        /// own, leaves the send to its confirmation instead of failing a transfer that arrived.
        @Test
        func `A refused close after every block was acknowledged still completes on the receiver's terminate`() async throws {
            let harness = JingleInitiatorHarness { iq in
                if iq.child(named: "close", namespace: XMPPNamespaces.ibb) != nil {
                    throw JingleModule.JingleError.transportFailed("item-not-found")
                }
                return nil
            }
            let sid = try await startIBBSend(harness)
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [1, 2, 3]) }
            #expect(try await harness.sentIQ(matching: { $0.child(named: "close", namespace: XMPPNamespaces.ibb) != nil }) != nil)

            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])
            let outcome = try await boundedOutcome { try await send.value }
            guard case .success? = outcome else {
                Issue.record("Expected the send to return, got \(String(describing: outcome))")
                return
            }
            #expect(try await harness.event(matching: JingleInitiatorHarness.isCompletion) != nil)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }

        @Test
        func `A success terminate before the send starts fails as canceled`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await startIBBSend(harness)

            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])
            #expect(try await harness.event { if case .jingleFileTransferFailed(sid, _, .cancel) = $0 { true } else { false } } != nil)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await harness.module.sendFileData(sid: sid, data: [1, 2, 3])
            }
        }

        @Test
        func `A receive whose terminate fails to send still reports exactly one event`() async throws {
            let harness = JingleInitiatorHarness(failingActions: [JingleAction.sessionTerminate.rawValue])
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            #expect(try await harness.module.receiveFileData(sid: "sid-1") == [1, 2, 3])
            #expect(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue) != nil)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }
    }
}
