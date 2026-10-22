import DuckoTestSupport
import Testing
@testable import DuckoXMPP

enum JingleTransportDeadlineTests {
    private static let candidateError = JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))

    private static func isTimeout(_ event: XMPPEvent) -> Bool {
        if case .jingleFileTransferFailed(_, .timeout) = event { return true }
        return false
    }

    /// Expects `harness` to have given up on its send: a timeout event, a session-terminate carrying `<timeout/>`, and
    /// `wait` failing.
    private static func expectTimedOut(_ harness: JingleInitiatorHarness, wait: Task<Void, any Error>) async throws {
        #expect(try await harness.event(matching: isTimeout) != nil)
        let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
        #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "timeout") != nil)
        let outcome = try await boundedOutcome { try await wait.value }
        guard case let .failure(error)? = outcome else {
            Issue.record("Expected the transport wait to fail, got \(String(describing: outcome))")
            return
        }
        #expect(error as? JingleModule.JingleError == .transportNegotiationFailed("The transfer timed out"))
    }

    struct SenderDeadline {
        /// The deadline starts at the peer's accept: until then the recipient is still deciding, however long that takes.
        @Test
        func `A peer that accepts and then goes silent times the send out, but an unanswered offer does not`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(transportReadyWait: .milliseconds(300)))
            let sid = try await harness.initiate()
            let wait = Task { try await harness.module.awaitTransportReady(sid: sid) }
            #expect(try await harness.event(timeout: .milliseconds(600), matching: JingleInitiatorHarness.isFailure) == nil)

            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)

            try await expectTimedOut(harness, wait: wait)
        }

        @Test
        func `An IBB fallback the peer never accepts times the send out`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(transportReadyWait: .milliseconds(300)))
            let sid = try await harness.initiate()
            let wait = Task { try await harness.module.awaitTransportReady(sid: sid) }
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            try harness.receive(action: JingleAction.transportInfo.rawValue, sid: sid, payload: [candidateError])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)

            try await expectTimedOut(harness, wait: wait)
        }

        /// The deadline only applies while nothing is ready, so a transfer under way is left to its own limits.
        @Test
        func `A send whose transport became ready is not timed out`() async throws {
            // Long enough for the setup below to finish under parallel test load, which a short deadline can outlast.
            let deadline = Duration.seconds(1)
            let harness = JingleInitiatorHarness(timing: JingleTiming(transportReadyWait: deadline))
            let sid = try await harness.initiate()
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            try harness.receive(action: JingleAction.transportInfo.rawValue, sid: sid, payload: [candidateError])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)
            try harness.receive(action: JingleAction.transportAccept.rawValue, sid: sid, payload: [JingleInitiatorHarness.ibbContent()])
            try await harness.module.awaitTransportReady(sid: sid)

            #expect(try await harness.event(timeout: deadline + .milliseconds(500), matching: JingleInitiatorHarness.isFailure) == nil)
        }
    }

    struct FallbackAwaitsAccept {
        @Test
        func `A sender waits for the peer to accept its IBB fallback`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(transportReadyWait: .seconds(2)))
            let sid = try await harness.initiate()
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            try harness.receive(action: JingleAction.transportInfo.rawValue, sid: sid, payload: [candidateError])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)

            let wait = Task { try await harness.module.awaitTransportReady(sid: sid) }
            try await Task.sleep(for: .milliseconds(100))
            // Armed: a second wait is refused only while the first is parked.
            let module = harness.module
            let probe = try await boundedOutcome(timeout: .milliseconds(200)) { try await module.awaitTransportReady(sid: sid) }
            guard case let .failure(probeError)? = probe,
                  probeError as? JingleModule.JingleError == .transportFailed("The transfer is already waiting for a connection") else {
                Issue.record("Expected the first wait to be parked, got \(String(describing: probe))")
                return
            }
            // A send that skips the wait is refused too: the IBB stream is set up but not yet the transport.
            await #expect(throws: JingleModule.JingleError.transportFailed("No connection is open for the transfer")) {
                try await module.sendFileData(sid: sid, data: [1, 2, 3])
            }

            try harness.receive(action: JingleAction.transportAccept.rawValue, sid: sid, payload: [JingleInitiatorHarness.ibbContent()])
            let outcome = try await boundedOutcome { try await wait.value }
            guard case .success? = outcome else {
                Issue.record("Expected the wait to resolve on transport-accept, got \(String(describing: outcome))")
                return
            }
        }
    }
}
